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

# taddy, the Tcl cADDY, is a tool to assist with debugging EDA tools by abstracting them
# from the customer environment.
#
# USAGE:
#   a.  source taddy.tcl
#   b.  taddy_setup PATH
#           where PATH is the name of the script taddy is to generate
#   c.  taddy_eval {source PATH}
#           where PATH is the user script to call
#
# Taddy will detect all calls that the user's scripts make to the vendor tool and echo
# them to the generated script, abstracted from the user's environment and algorithms.
# The "unrolled" script can be rerun to produce the same results in the EDA tool without
# any supporting scripts.
#
# METHODOLOGY:
#   Taddy leverages Tcl's built-in nested interpreter functionality. This has existed
#   since Tcl 8.3 and so is in the vast majority of modern EDA tools. It runs the user's
#   script inside of the slave interpreter and creates shim procedures between the slave
#   and master interpreter to intercept all calls made to the vendor commands. The
#   intercepted calls are written out to a script. 
#
#   The generated script is useful for debugging the tool, the user's environment, or
#   for passing off test cases to the vendor without having to pass off the entire user
#   environment.


##############################################################################
# Preamble: declare global constants in master interpreter
##############################################################################
global TADDY_DEBUG
global TADDY_TCLSH
global TADDY_TOOL

set TADDY_DEBUG false      ;# set to "true" to get debug trace messages printed to stdout
                           ;# and "taddy_debug.log"
set TADDY_TCLSH tclsh8.5   ;# set to executable name of Tcl in your environment
                           ;# This should resolve to a tclsh binary that is equivalent
                           ;# in version to your tools' Tcl version (e.g. 8.4, 8.5, etc.)

# Determine target tool using some tool-specific marker. Be sure to use a non-fatal
# expression so that it doesn't cause an exception in other tools.
if {[llength [info commands conformal_news]]} {
    set TADDY_TOOL conformal
} elseif {[llength [info vars rc_mode]]} {
    set TADDY_TOOL rc
} else {
    error "Unsupported tool for shim!"
}


##############################################################################
# Shim configuration
#
# This section sets up parameters used to create the shims. It will likely
# have to modified to support additional EDA tools.
##############################################################################

#
# These namespaces should be copied into the slave interpreter, i.e. source code
# should be copied and made local to slave interpreter without a shim pointing it
# to the master interpreter. Required to get several Tcl built-ins, including package 
# handling. Applies recursively.
#
set copied_namespaces {::tcl ::msgcat}

#
# These namespaces should be aliased directly without a shim wrapper. Only works if there
# are no namespace-level vars that will get corrupted. Applies recursively.
# Unused at this time, but could be useful in the future.
#
set aliased_namespaces {}

#
# Individual procedures to copy. Like $copied_namespaces, but more granular.
# Useful for cases where EDA tool has overridden a Tcl built-in, or we need
# to copy a built-in Tcl procedure to the slave interpreter
#
set copied_procs [list redirect pkg_mkIndex tclPkgUnknown]

if {$TADDY_TOOL == "rc"} {
    lappend copied_procs unknown
}

#
# these procs/commands cannot be auto-shimmed because they are not returned
# via info commands/info procs from within the vendor's tool.
#
set hidden_tcl_commands [list]

if {$TADDY_TOOL == "rc"} {
    lappend hidden_tcl_commands \
        get_attr calling_proc write
}

#
# These procs are short-circuited, forced to return 0. This is helpful for
# some tools that customize the Tcl environment in ways that don't tolerate
# being shimmed. 
#
set bypassed_tcl_commands [list]

# Useful for RC-based scripts. They may opt to register a help message with the
# tool to leverage built-in documentation management. Unfortunately, the master
# interpreter has no knowledge of the user's commands (as they live in the 
# slave interpreter, so they are destined to always fail.
if {$TADDY_TOOL == "rc"} {
    lappend bypassed_tcl_commands add_command_help 
}


#
# tcl_commands: these procs/commands should NOT be shim'ed, but rather left to execute 
# normally
#

# preload it with a list of standard Tcl procedures. use exec to call a standard Tcl shell 
# so as not to include any vendor-specific commands
set tcl_commands [exec echo {puts [join [lsort [info commands]] \n]} | $TADDY_TCLSH]

# Don't expose taddy commands to slave
lappend tcl_commands taddy 
lappend tcl_commands debug

# Tool-specific amendments are below
if {$TADDY_TOOL == "rc"} {
    # Commands to remove from alias exclusion. These are commands that we want 
    # unrolled as part of execution of the user's scripts

    # TODO: determine why these are required and document the reason, or remove
    foreach command_to_remove {
        apply
        cd
        chan
        lassign
        lrepeat
        lreverse
        pwd
        unload
    } {
        set index [lsearch $tcl_commands $command_to_remove
        set tcl_commands [lreplace $tcl_commands $index $index {}]
    }

    # Commands to add to alias exclusion
     
    # RC built-in for IO redirection. Usually contains blocks of user code.
    lappend tcl_commands redirect
    # RC's alias for Tcl "source" builtin.
    lappend tcl_commands tcl_source
}

if {$TADDY_TOOL == "conformal"} {
    # Nothing to add/remove
}


##############################################################################
# Procedures
##############################################################################

# A wrapper for "puts" that adds some Taddy-specific useful extensions, namely that
# it echos all output to both stdout and Taddy output script.
proc debug {str} {
    global TADDY_DEBUG
    
    # edit code to enable debug traces
    if {$TADDY_DEBUG} {
        global debug_fh
        if {[info exists in_shim]} {
            set prefix "in slave : "
        } else {
            set prefix "in master: "
        }
        puts           "DEBUG: $prefix$str"
        puts $debug_fh "DEBUG: $prefix$str"
    }
}

# create 'shim' proc in nested interpreter "taddy" to intercept calls and send to master
# interpreter
#
# Args:
#   tool_proc: name of procedure to shim
#   flexible (default false): only create shim if procedure exists. Reserved for 
#     invocations from vendor-specific "unknown" procedures
#
# Returns:
#   0: no shim created. Was reserved Tcl command, slated to be bypassed, or did not exist
#      in master interpreter
#   1: shim created
proc create_shim {tool_proc {flexible false}} {
    global tcl_commands
    global hidden_tcl_commands
    global bypassed_tcl_commands 

    # when called from 'unknown', it is prefixed with :: and that screws up the lsearch'es below
    set tool_proc [regsub {^::} $tool_proc {}]

    if {$flexible && ![llength [info procs $tool_proc]]} {
        return 0
    }

    if {[lsearch $tcl_commands $tool_proc] > -1} {
        debug "Skipped shimming $tool_proc: build-in Tcl command"
    } else {
        if {[lsearch $bypassed_tcl_commands $tool_proc] > -1} {
            debug "Skipped shimming $tool_proc: to be bypassed"

            namespace eval ::shim {
                if {![llength [info procs $tool_proc]]} {
                    proc $tool_proc args " 
                        global shim_fh
                        debug \$shim_fh \"# bypassed: $tool_proc \$args\"
                        return 0
                    "
                }
            }
            taddy alias $tool_proc ::shim::$tool_proc
        } else {
            debug "will create shim => $tool_proc"
            
            # preserve namespace hierarchy in master/slave interpreters
            if {[regexp {::} $tool_proc]} {
                set target_ns ::shim::[namespace qualifiers $tool_proc]
            } else {
                set target_ns ::shim
            }
            debug "creating in master: ${target_ns}::[namespace tail $tool_proc]"
            namespace eval $target_ns {set dummy 0}
            
            # define shim procedure in master
            # It is responsible for printing out command/args to Taddy output script,
            # capturing the return value, and passing it back to the slave interpreter.
            #
            # A bit more complicated, some procedures use upvar to pass values back
            # to the caller. This would seem trivial in practice, thinking that we can
            # simply upvar to the calling scope in the slave interpreter, but this is not
            # possible: the call stack is broken between master/slave interpreters.
            #
            # To get around this, we set the variables to <slave>::shim::uplevel::${var},
            # then in the calling procedure inside of the slave interpreter set them
            # via upvar. The variables in ::shim::uplevel are deleted as they are set
            # in the calling scope.  
            #
            # Note that the code is passed as a quoted string to allow variable 
            # interpolation, so a lot of \ are required. Nesting "" for sub-procedure
            # calls is a bit too hard to follow, so [list] is used on occasion for the
            # sole purpose of concatenating together strings.
            proc ::shim::$tool_proc args " 
                global shim_fh
                puts \$shim_fh \"$tool_proc \$args\"
                set __ret__ \[eval \"::$tool_proc \$args\"]
                set level \[taddy eval info level]
                debug \"start: \$level\"
                for {set i 0} {\$i < \$level} {incr i} {
                    debug \"\$i => \[taddy eval info level \$i]\"
                }
                unset level
                unset i
                foreach __v__ \[info vars] {
                    if {\[lsearch {__ret__ shim_fh args} \$__v__] == -1} {
                        debug \"new var! \$__v__\"
                        taddy eval \[list namespace eval ::shim::uplevel \[list set \$__v__ \[set \$__v__]]]
                        debug \"sending \$__v__ => \[set \$__v__] \"
                    }
                }
                return \$__ret__
            "

            #
            # create slave-side procedure. Do this so that uplevel'ed reference vars can be
            # introduced back into the slave interp's call stack
            #
            debug "creating in slave : ::shim::$tool_proc"
            if {[regexp {::} $tool_proc]} {
                taddy eval "
                    if {!\[namespace exists [namespace qualifiers $tool_proc]]} {
                        namespace eval [namespace qualifiers $tool_proc] {set dummy 0}
                    }
                "
            }
            taddy eval [list \
                proc $tool_proc args "
                    set ret \[eval ::shim::$tool_proc \$args]
                    foreach v \[namespace eval ::shim::uplevel {info vars}] {
                        if {\[info exists ::shim::uplevel::\$v]} {
                            uplevel 1 \[list set \$v \[set ::shim::uplevel::\$v]]
                            debug \"receiving \$v => \[set ::shim::uplevel::\$v ]\"
                            unset ::shim::uplevel::\$v
                        }
                    }
                    return \$ret
                "
            ]

            debug "linking master/slave: ::shim::$tool_proc ::shim::$tool_proc"
            taddy alias ::shim::$tool_proc ::shim::$tool_proc

            return 1
        }
    }
    return 0
}

# alias in namespaces, recursively
proc alias_ns {ns} {
    foreach p [namespace eval $ns {::info procs}] {
        debug "alias ${ns}::$p ${ns}::$p"
        taddy alias ${ns}::$p ${ns}::$p
    }

    foreach child_ns [namespace children $ns] {
        alias_ns $child_ns
    }
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

##############################################################################
# Create slave interpreter, create shim procedures in master/slave, and link them
# together via aliases
##############################################################################

# Used by calling environment to initialize global variables.
#
# capture_script_path: file path to write captured script to
proc taddy_setup {capture_script_path} {
    global debug_fh 
    global shim_fh
    global TADDY_DEBUG
    global TADDY_TOOL
    global hidden_tcl_commands
    global bypassed_tcl_commands
    global aliased_namespaces
    global copied_namespaces
    global copied_procs
    
    # edit code to enable debugging
    if {$TADDY_DEBUG} {
        set debug_fh [open taddy_debug.log w]
    }
    set shim_fh  [open $capture_script_path w]

    # Delete previous taddy interpreter and environment, if they exist
    if {[interp exists taddy]} {
        interp delete taddy
    }
    if {[namespace exists ::shim]} {
        namespace delete ::shim
    }

    interp create taddy
    taddy alias debug debug

    # used by some user code
    foreach var {::argv0} {
        if {[info exists $var]} {
            taddy eval "set $var [set $var]"
        }
    }

    # "Random hacks" section
    if {$TADDY_TOOL == "rc"} {
        # required for 'unknown' to auto-fix commands
        taddy eval {namespace eval rc {set always_interact 1}}

        # Load in customized 'unknown' procedure. Must be done before copy procedures invoked
        # below.
        #
        # RC/Genus is bundled with a substantial amount of Tcl code that is treated/
        # documented as native RC commands. They should not be shimmed. However, they do
        # not exist in the Tcl namespace when taddy would first be invoked, so there must
        # be a way of intercepting them as they are invoked by the user's scripts. The
        # means for doing so is via the "unknown" procedure, which auto-loads RC's bundled
        # packages as they are invoked. In there, it is trivial to invoke create_shim
        # blindly for each invocation of "unknown", so long as "flexible" is set to true.
        # In that situation, create_shim checks to see if the procedure exists in the master
        # interpreter and only shims it if it exists.
        #
        # Unfortunately, the modified "unknown" source code cannot be distributed with Taddy 
        # as it is Cadence copyrighted. However, it's easy to do yourself.
        #
        # a) Write out "unknown":
        #   puts [info body ::unknown]
        # b) modify to add this near the top
        #   if {[create_shim $cmd true]} {
        #       debug "Created shim from 'unknown' for $cmd"
        #       return [uplevel 1 $args]
        #   }
        # c) source it below
        #
        # TODO: may be possible to automatically inject this code at top of ::unknown
        # procedure body for all tools
    
        #source path/to/file
    }

    # Pick a package at random to load so that tclPkgUnknown and tcl::tm are auto-loaded
    # and get properly copied into the slave interpreter. msgcat is native to Tcl and should
    # be present in all tools.
    package require msgcat 

    # Shim all procedures in global namespace
    foreach tool_proc [concat [info procs] [info commands] $hidden_tcl_commands $bypassed_tcl_commands] {
        create_shim $tool_proc    
    }

    # Alias procedures in select namespaces, without shimming
    foreach current_ns $aliased_namespaces {
        alias_ns $current_ns
    }

    # Copy entire namespaces from master to slave, without shimming
    foreach current_ns $copied_namespaces {
        copy_ns $current_ns
    }

    # Copy select procedures from master to slave, without shimming, overwriting previously-existing shim
    foreach p $copied_procs  {
        if {[llength [info proc $p]]} {
	        taddy eval [list proc $p [info args $p] [info body $p]]
	    } else {
	    	debug "Warning: procedure '$p' of 'copied_procs' does not exist."
	    }
    }
}
