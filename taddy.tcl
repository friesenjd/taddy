# Copyright 2015 Joseph Friesen
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

##############################################################################
# Used by calling environment to initialize global variables.
#
# capture_script_path: file path to write captured script to
##############################################################################
proc taddy_setup {capture_script_path} {
    global debug_fh 
    global shim_fh
    
    # edit code to enable debugging
    if {0} {
        set debug_fh [open debug.log w]
    }
    set shim_fh  [open shim_log.txt w]
}

##############################################################################
# Preamble
##############################################################################

# Determine target tool
if {[llength [info commands conformal_news]]} {
    set SHIM_TOOL conformal
} elseif {[llength [info vars rc_mode]]} {
    set SHIM_TOOL rc
} else {
    error "Unsupported tool for shim!"
}

if {[interp exists taddy]} {
    interp delete taddy
}
interp create taddy

proc debug {str} {
    # edit code to enable debug traces
    if {0} {
        global debug_fh
        if {[info exists in_shim]} {
            set prefix "in slave : "
        } else {
            set prefix "in master: "
        }
        if {1} {
            puts           "DEBUG: $prefix$str"
            puts $debug_fh "DEBUG: $prefix$str"
        }
    }
}

# use within code below. puts isn't exposed by default and, if it is, will
# cause 'redirect' to die
taddy alias puts_debug puts

if {$SHIM_TOOL == "rc"} {
    # used within ::CAD
    taddy eval "set ::argv0 $::argv0"

    # pre-load package for read_sdc
    catch {dc::all_inputs}
    catch {dc::unknown}

    # add debug traces for use in read_sdc
    source /proj/belmar_revb_kel/devel/friesenj/work.trunk/tbcs/belmar_monolithic/common/scripts/dc::unknown.tcl

    # load in customized 'unknown' procedure
    source /proj/belmar_revb_kel/devel/friesenj/work.trunk/tbcs/belmar_monolithic/common/scripts/unknown.rc.tcl
}
if {$SHIM_TOOL == "conformal"} {
    # load one random package so that tclPkgUnknown and
    # tcl::tm are auto-loaded
    package require msgcat 
}

##############################################################################
# Shim configuration
##############################################################################

#
# these namespaces should be copied into the slave interpreter. applies recursively.
# required to get several Tcl built-ins, including package handling.
#
set copied_namespaces {::tcl}

#
# these namespaces should be aliased. Only works if there are no namespace-level vars
# that will get corrupted
#
set aliased_namespaces {}

#
# procedures to copy (i.e. those that Cadence has modified)
#
set copied_procs [list redirect]

if {$SHIM_TOOL == "conformal"} {
    lappend copied_procs tclPkgUnknown
}
if {$SHIM_TOOL == "rc"} {
    lappend copied_procs unknown
}

#
# these procs/commands cannot be auto-shimmed because they are not returned
# via info commands/info procs
#
set hidden_tcl_commands [list]

if {$SHIM_TOOL == "rc"} {
    lappend hidden_tcl_commands \
        get_attr calling_proc write
}

#
# these procs are bypassed, i.e. forced to return 0
#
set bypassed_tcl_commands {
    add_command_help
}

#
#
# these procs/commands should NOT be shim'ed, but rather left to execute normally
#
if {$SHIM_TOOL == "rc"} {
    set tcl_commands {
        after
        append
        array
        binary
        break
        case
        catch
        clock
        close
        concat
        continue
        dict
        encoding
        eof
        error
        eval
        exec
        exit
        expr
        fblocked
        fconfigure
        fcopy
        file
        fileevent
        flush
        for
        foreach
        format
        gets
        glob
        global
        history
        if
        incr
        info
        interp
        join
        lappend
        lindex
        linsert
        list
        llength
        load
        lrange
        lreplace
        lsearch
        lset
        lsort
        namespace
        open
        package
        pid
        pkg_mkIndex
        proc
        puts
        read
        redirect
        regexp
        regsub
        rename
        return
        scan
        seek
        set
        socket
        source
        split
        string
        subst
        switch
        tclLog
        unknown
        tclPkgUnknown
        tcl_source
        tell
        time
        trace
        unset
        update
        uplevel
        upvar
        variable
        vwait
        while
        auto_load_index auto_import auto_execok auto_qualify auto_load 
    }
}

# must be invoked from a standard Tcl shell so as not to include any vendor-specific commands
if {$SHIM_TOOL == "conformal"} {
    # intentionally over-write
    set tcl_commands [exec echo {puts [join [lsort [info commands]] \n]} | tclsh8.5]
}

lappend tcl_commands taddy 

#
# create 'shim' proc in nested interpreter taddy to intercept calls and send to master
# interpreter
#
# Argus:
#   flexible (default 0): only create shim if procedure exists. Not the default, as some procs
#     are not loaded after Tcl initialization but need to be shimmed
#
# Returns:
#   0: no shim created. Was reserved Tcl command or slated to be bypassed or did not exist
#      in master interpreter
#   1: shim created
proc create_shim {rc_proc {flexible false}} {
    global tcl_commands
    global hidden_tcl_commands
    global bypassed_tcl_commands 

    # when called from 'unknown', it is prefixed with :: and that screws up the lsearch'es below
    set rc_proc [regsub {^::} $rc_proc {}]

    if {$flexible && ![llength [info procs $rc_proc]]} {
        return 0
    }

    if {[lsearch $tcl_commands $rc_proc] > -1} {
        debug "Skipped shimming $rc_proc: build-in Tcl command"
    } else {
        if {[lsearch $bypassed_tcl_commands $rc_proc] > -1} {
            debug "Skipped shimming $rc_proc: to be bypassed"

            namespace eval ::shim {
                if {![llength [info procs $rc_proc]]} {
                    proc $rc_proc args " 
                        global shim_fh
                        puts \$shim_fh \"# bypassed: $rc_proc \$args\"
                        return 0
                    "
                }
            }
            taddy alias $rc_proc ::shim::$rc_proc
        } else {
            debug "will create shim => $rc_proc"
            if {[regexp {::} $rc_proc]} {
                set target_ns ::shim::[namespace qualifiers $rc_proc]
            } else {
                set target_ns ::shim
            }
            debug "creating in master: ${target_ns}::[namespace tail $rc_proc]"
            namespace eval $target_ns {set blah blah}
            proc ::shim::$rc_proc args " 
                global shim_fh
                puts \$shim_fh \"$rc_proc \$args\"
                set __ret__ \[eval \"::$rc_proc \$args\"]
                set level \[taddy eval info level]
                puts \"start: \$level\"
                for {set i 0} {\$i < \$level} {incr i} {
                    puts \"\$i => \[taddy eval info level \$i]\"
                }
                unset level
                unset i
                foreach __v__ \[info vars] {
                    if {\[lsearch {__ret__ shim_fh args} \$__v__] == -1} {
                        puts \"new var! \$__v__\"
                        taddy eval \[list namespace eval ::shim::uplevel \[list set \$__v__ \[set \$__v__]]]
                        puts \"sending \$__v__ => \[set \$__v__] \"
                    }
                }
                return \$__ret__
            "

            #
            # create slave-side procedure. Do this so that uplevel'ed reference vars can be
            # introduced back into the slave interp's call stack
            #
            debug "creating in slave : ::shim::$rc_proc"
            if {[regexp {::} $rc_proc]} {
                taddy eval "
                    if {!\[namespace exists [namespace qualifiers $rc_proc]]} {
                        namespace eval [namespace qualifiers $rc_proc] {set blah 0}
                    }
                "
            }
            taddy eval [list \
                proc $rc_proc args "
                    set ret \[eval ::shim::$rc_proc \$args]
                    foreach v \[namespace eval ::shim::uplevel {info vars}] {
                        if {\[info exists ::shim::uplevel::\$v]} {
                            uplevel 1 \[list set \$v \[set ::shim::uplevel::\$v]]
                            puts_debug \"receiving \$v => \[set ::shim::uplevel::\$v ]\"
                            unset ::shim::uplevel::\$v
                        }
                    }
                    return \$ret
                "
            ]

            debug "linking master/slave: ::shim::$rc_proc ::shim::$rc_proc"
            taddy alias ::shim::$rc_proc ::shim::$rc_proc

            return 1
        }
    }
    return 0
}

# alias in namespaces, recursively
proc alias_ns {ns} {
    foreach p [namespace eval $ns {::info procs}] {
        puts "alias ${ns}::$p ${ns}::$p"
        taddy alias ${ns}::$p ${ns}::$p
    }

    foreach child_ns [namespace children $ns] {
        alias_ns $child_ns
    }
}

# ...
if {[namespace exists ::shim]} {
    namespace delete ::shim
}

foreach rc_proc [concat [info procs] [info commands] $hidden_tcl_commands $bypassed_tcl_commands] {
    create_shim $rc_proc    
}

foreach current_ns $aliased_namespaces {
    alias_ns $current_ns
}

#
# copy over namespaces
#
proc copy_ns {ns} {
    debug "Copying namespace $ns"
    foreach var [namespace eval $ns {::info vars}] {
        #debug "  variable $var"
        if {[info exists ${ns}::$var]} {
            if {[array exists ${ns}::$var]} {
                taddy eval [list namespace eval $ns [list array set $var [array get ${ns}::$var]]]
            } else {
                taddy eval [list namespace eval $ns [list set $var [set ${ns}::$var]]]
            }
        }
    }

    foreach p [namespace eval $ns {::info procs}] {
        debug "  proc     $p"
        taddy eval [list namespace eval $ns [list proc $p [info args ${ns}::$p] [info body ${ns}::$p]]]
    }

    foreach ns [namespace children $ns] {
        copy_ns $ns
    }
}

foreach current_ns $copied_namespaces {
    copy_ns $current_ns
}

foreach p $copied_procs  {
    taddy eval [list proc $p [info args $p] [info body $p]]
}

if {$SHIM_TOOL == "rc"} {
    # required for 'unknown' to auto-fix commands
    taddy eval {namespace eval rc {set always_interact 1}}
}

