# *- bash -*

# INCLUDE BASH LIBRARY
. ${panpipe_bindir}/panpipe_lib || exit 1

#############
# CONSTANTS #
#############

PPL_IS_COMPLETED=0
PPL_HAS_WRONG_OUTDIR=1
PPL_FAILED=2
PPL_IS_NOT_COMPLETED=3
POST_PPL_COMPL_ACTIONS_FINISHED_FILENAME=".post_ppl_compl_actions_finished"

########
print_desc()
{
    echo "pipe_exec_batch executes a batch of pipelines"
    echo "type \"pipe_exec_batch --help\" to get usage information"
}

########
usage()
{
    echo "pipe_exec_batch           -f <string> -m <int> [-o <string>] [-u <int>]"
    echo "                          [-k <string>] [--help]"
    echo ""
    echo "-f <string>               File with a set of pipe_exec commands (one"
    echo "                          per line)"
    echo "-m <int>                  Maximum number of pipelines executed simultaneously"
    echo "-o <string>               Output directory where the pipeline output should be"
    echo "                          moved (if not given, the output directories are"
    echo "                          provided by the pipe_exec commands)"
    echo "-u <int>                  Maximum percentage of unfinished steps that is"
    echo "                          allowed when evaluating if pipeline execution is"
    echo "                          complete (0 by default)"
    echo "-k <string>               Execute script implementing a software hook after"
    echo "                          finishing the execution of each pipeline"
    echo "--help                    Display this help and exit"
}

########
read_pars()
{
    f_given=0
    m_given=0
    o_given=0
    u_given=0
    max_unfinished_step_perc=0
    k_given=0
    while [ $# -ne 0 ]; do
        case $1 in
            "--help") usage
                      exit 1
                      ;;
            "-f") shift
                  if [ $# -ne 0 ]; then
                      file=$1
                      f_given=1
                  fi
                  ;;
            "-m") shift
                  if [ $# -ne 0 ]; then
                      maxp=$1
                      m_given=1
                  fi
                  ;;
            "-o") shift
                  if [ $# -ne 0 ]; then
                      outd=$1
                      o_given=1
                  fi
                  ;;
            "-u") shift
                  if [ $# -ne 0 ]; then
                      max_unfinished_step_perc=$1
                      u_given=1
                  fi
                  ;;
            "-k") shift
                  if [ $# -ne 0 ]; then
                      k_val=$1
                      k_given=1
                  fi
                  ;;
        esac
        shift
    done   
}

########
get_unfinished_step_perc()
{
    local pipe_status_output_file=$1
    $AWK '{if ($1=="*") printf"%d",$13*100/$4}' ${pipe_status_output_file}
}

########
get_ppl_status()
{
    local pipe_exec_cmd=$1
    local outd=$2

    # Extract output directory from command
    local pipe_cmd_outd=`read_opt_value_from_line "${pipe_exec_cmd}" "--outdir"`
    if [ ${pipe_cmd_outd} = ${OPT_NOT_FOUND} ]; then
        return ${PPL_HAS_WRONG_OUTDIR}
    fi

    # Check if final output directory was provided
    if [ "${outd}" != "" ]; then
        # Get pipeline directory after moving
        local final_outdir=`get_dest_dir_for_ppl ${pipe_cmd_outd} ${outd}`
        if [ -d ${final_outdir} ]; then
            # If output directory exists, it is assumed that the
            # pipeline was completed
            return ${PPL_IS_COMPLETED}
        fi
    fi

    # If original output directory exists then check pipeline status
    if [ -d ${pipe_cmd_outd} ]; then
        # Obtain pipeline status
        tmpfile=`${MKTEMP}`
        ${panpipe_bindir}/pipe_status -d ${pipe_cmd_outd} > ${tmpfile} 2>&1
        exit_code=$?

        # Obtain percentage of unfinished steps
        local unfinished_step_perc=`get_unfinished_step_perc ${tmpfile}`
        rm ${tmpfile}
        
        # Evaluate exit code of pipe_status
        case $exit_code in
            ${PIPELINE_FINISHED_EXIT_CODE}) return ${PPL_IS_COMPLETED}
                                            ;;
            ${PIPELINE_UNFINISHED_EXIT_CODE}) if [ ${unfinished_step_perc} -gt ${max_unfinished_step_perc} ]; then
                                                  return ${PPL_FAILED}
                                              else
                                                  return ${PPL_IS_COMPLETED}
                                              fi
                                              ;;
            *) return ${PPL_IS_NOT_COMPLETED}
               ;;
        esac
    else
        return ${PPL_IS_NOT_COMPLETED}
    fi
}

########
wait_simul_exec_reduction()
{
    # Example of passing associative array as function parameter
    # local _assoc_array=$(declare -p "$1")
    # eval "local -A assoc_array="${_assoc_array#*=}
    local maxp=$1
    local SLEEP_TIME=100
    local end=0
    local num_active_pipelines=${#PIPELINE_COMMANDS[@]}
    
    while [ ${end} -eq 0 ] ; do
        # Iterate over active pipelines
        local num_finished_pipelines=0
        local num_failed_pipelines=0
        for pipeline_outd in "${!PIPELINE_COMMANDS[@]}"; do
            # Retrieve pipe command
            local pipe_exec_cmd=${PIPELINE_COMMANDS[${pipeline_outd}]}

            # Check if pipeline has finished execution
            get_ppl_status "${pipe_exec_cmd}" ${outd}
            local exit_code=$?
            case $exit_code in
                ${PPL_HAS_WRONG_OUTDIR}) echo "Error: pipeline command does not contain --outdir option">&2
                                         return 1
                                         ;;
                ${PPL_IS_COMPLETED}) num_finished_pipelines=$((num_finished_pipelines+1))
                                     ;;
                ${PPL_FAILED}) num_failed_pipelines=$((num_failed_pipelines+1))
                               ;;
            esac
        done
        
        # Sanity check: if maximum number of active pipelines has been
        # reached and all pipelines are unfinished, then it is not
        # possible to continue execution
        if [ ${num_active_pipelines} -ge ${maxp} -a ${num_failed_pipelines} -eq ${num_active_pipelines} ]; then
            if [ ${maxp} -gt 0 ]; then
                echo "Error: all active pipelines failed and it is not possible to execute new ones" >&2
                return 1
            else
                echo "Error: all active pipelines failed" >&2
                return 1
            fi
        fi
        
        # Obtain number of pending pipelines
        local pending_pipelines=$((num_active_pipelines - num_finished_pipelines))

        # Wait if number of pending pipelines is equal or greater than
        # maximum
        if [ ${pending_pipelines} -ge ${maxp} ]; then
            sleep ${SLEEP_TIME}
        else
            end=1
        fi
    done
}

########
get_dest_dir_for_ppl()
{
    local pipeline_outd=$1
    local outd=$2    
    basedir=`$BASENAME ${pipeline_outd}`
    echo ${outd}/${basedir}
}

########
move_dir()
{
    local pipeline_outd=$1
    local outd=$2    
    destdir=`get_dest_dir_for_ppl ${pipeline_outd} ${outd}`
    
    # Move directory
    if [ -d ${destdir} ]; then
        echo "Error: ${destdir} exists" >&2
        return 1
    else
        mv ${pipeline_outd} ${outd} || return 1
    fi
}

########
exec_hook()
{
    local outd=$1

    # export variables
    export PIPE_EXEC_BATCH_PPL_OUTD=${outd}
    export PIPE_EXEC_BATCH_PPL_CMD=${PIPELINE_COMMANDS[${outd}]}

    # Execute script
    ${k_val}
    local exit_code=$?

    # unset variables
    unset PPL_OUTD
    unset PPL_CMD

    return ${exit_code}
}

########
post_ppl_compl_actions_are_finished()
{
    local pipeline_outd=$1
    local outd=$2

    if [ -z "${outd}" ]; then
        if [ -f ${pipeline_outd}/${POST_PPL_COMPL_ACTIONS_FINISHED_FILENAME} ]; then
            return 0
        else
            return 1
        fi
    else
        destdir=`get_dest_dir_for_ppl ${pipeline_outd} ${outd}`
        if [ -f ${destdir}/${POST_PPL_COMPL_ACTIONS_FINISHED_FILENAME} ]; then
            return 0
        else
            return 1
        fi
    fi    
}

########
signal_finish_of_post_ppl_compl_actions()
{
    local pipeline_outd=$1
    local outd=$2

    if [ -z "${outd}" ]; then
        touch ${pipeline_outd}/${POST_PPL_COMPL_ACTIONS_FINISHED_FILENAME}
    else
        destdir=`get_dest_dir_for_ppl ${pipeline_outd} ${outd}`
        touch ${destdir}/${POST_PPL_COMPL_ACTIONS_FINISHED_FILENAME}
    fi
}

########
exec_post_ppl_completion_actions()
{
    local pipeline_outd=$1
    local outd=$2

    # Check that ${pipeline_outd} directory exists
    if [ ! -d "${pipeline_outd}" ]; then
        echo "Warning: post pipeline completion actions cannot be executed because ${pipeline_outd} directory no longer exists" >&2
        return 1
    fi

    # Execute hook if requested
    if [ ${k_given} -eq 1 ]; then
        echo "- Executing hook implemented in ${k_val}" >&2
        exec_hook ${pipeline_outd}
        local exit_code_hook=$?
        case ${exit_code_hook} in
            1) echo "Warning: hook execution failed for pipeline stored in ${pipeline_outd} directory" >&2
               return 1
               ;;
            *) return ${exit_code_hook}
               ;;
        esac
    fi

    # Move directory if requested
    if [ ! -z "${outd}" ]; then
        echo "- Moving ${pipeline_outd} directory to ${outd}" >&2
        move_dir ${pipeline_outd} ${outd} || return 1
    fi

    # Signal finish of post pipeline completion actions
    signal_finish_of_post_ppl_compl_actions ${pipeline_outd} ${outd}
}
 
########
update_active_pipeline()
{
    local pipeline_outd=$1
    local outd=$2

    # Retrieve pipe command
    local pipe_exec_cmd=${PIPELINE_COMMANDS[${pipeline_outd}]}

    # Check if pipeline has finished execution
    get_ppl_status "${pipe_exec_cmd}" ${outd}
    local exit_code=$?
    
    case $exit_code in
        ${PPL_HAS_WRONG_OUTDIR}) echo "Error: pipeline command does not contain --outdir option">&2
                                 return 1
                                 ;;
        ${PPL_IS_COMPLETED}) echo "Pipeline stored in ${pipeline_outd} has completed execution" >&2
                             exec_post_ppl_completion_actions ${pipeline_outd} ${outd}
                             local exit_code_post_comp_actions=$?
                             # If post pipeline completion actions were
                             # successfully executed, remove pipeline
                             # from array of active pipelines
                             case $exit_code_post_comp_actions in
                                 0) unset PIPELINE_COMMANDS[${pipeline_outd}]
                                    ;;
                                 1) return 1
                                    ;;
                             esac
                             ;;
    esac
}

########
update_active_pipelines()
{
    local outd=$1
    
    local num_active_pipelines=${#PIPELINE_COMMANDS[@]}
    echo "Previous number of active pipelines: ${num_active_pipelines}" >&2
    
    # Iterate over active pipelines
    for pipeline_outd in "${!PIPELINE_COMMANDS[@]}"; do
        update_active_pipeline ${pipeline_outd} ${outd} || return 1
    done

    local num_active_pipelines=${#PIPELINE_COMMANDS[@]}
    echo "Updated number of active pipelines: ${num_active_pipelines}" >&2
}

########
extract_outd_from_command()
{
    local cmd=$1
    echo `read_opt_value_from_line "${cmd}" "--outdir"`
}

########
add_cmd_to_assoc_array()
{
    local cmd=$1

    # Extract output directory from command
    local dir=`extract_outd_from_command "${cmd}"`

    # Add command to associative array if directory was sucessfully retrieved
    if [ ${dir} = ${OPT_NOT_FOUND} ]; then
        return 1
    else
        PIPELINE_COMMANDS[${dir}]=${cmd}
        return 0
    fi
}

########
wait_until_pending_ppls_finish()
{
    wait_simul_exec_reduction 1 || return 1
}

########
process_ppl_compl_actions_if_required()
{
    local cmd=$1
    local outd=$2
    
    local pipeline_outd=`extract_outd_from_command "${cmd}"`
    if ! post_ppl_compl_actions_are_finished ${pipeline_outd} ${outd}; then
        echo "Warning, post pipeline completion actions were not finished, they will be executed now...">&2
        exec_post_ppl_completion_actions ${pipeline_outd} ${outd}
        local exit_code=$?
        if [ ${exit_code} -ne 0 ]; then
            return ${exit_code}
        fi
    fi
}

########
execute_batches()
{
    # Read file with pipe_exec commands
    lineno=1

    # Global variable declaration
    declare -A PIPELINE_COMMANDS

    # Process pipeline execution commands...
    while read pipe_exec_cmd; do

        # Execute built-in tilde expansion to avoid problems with "~"
        # symbol in file and directory paths
        pipe_exec_cmd=`expand_tildes "${pipe_exec_cmd}"`
        
        echo "* Processing line ${lineno}..." >&2
        echo "" >&2
        
        echo "** Wait until number of simultaneous executions is below the given maximum..." >&2
        wait_simul_exec_reduction ${maxp} || return 1
        echo "" >&2
            
        echo "** Update array of active pipelines..." >&2
        update_active_pipelines "${outd}" || return 1
        echo "" >&2

        echo "** Check if pipeline is already completed..." >&2
        get_ppl_status "${pipe_exec_cmd}" ${outd}
        local exit_code=$?
        case $exit_code in
            ${PPL_HAS_WRONG_OUTDIR}) echo "Error: pipeline command does not contain --outdir option">&2
                                     return 1
                                     ;;
            ${PPL_IS_COMPLETED}) echo "yes">&2
                                 process_ppl_compl_actions_if_required "${pipe_exec_cmd}" ${outd}
                                 local exit_code_post_comp_actions=$?
                                 if [ ${exit_code_post_comp_actions} -eq 1 ]; then
                                     return 1
                                 fi
                                 ;;
            ${PPL_FAILED}) echo "no">&2
                           ;;
            ${PPL_IS_NOT_COMPLETED}) echo "no">&2
                                     ;;
        esac
        echo "" >&2
        
        if [ ${exit_code} -eq ${PPL_IS_NOT_COMPLETED} -o ${exit_code} -eq ${PPL_FAILED} ]; then
            echo "**********************" >&2
            echo "** Execute pipeline..." >&2
            echo ${pipe_exec_cmd} >&2
            ${pipe_exec_cmd} || return 1
            echo "**********************" >&2
            echo "" >&2
            
            echo "** Add pipeline command to associative array..." >&2
            add_cmd_to_assoc_array "${pipe_exec_cmd}" || { echo "Error: pipeline command does not contain --outdir option">&2 ; return 1; }
            echo "" >&2
        fi
        
        # Increase lineno
        lineno=$((lineno+1))
        
    done < ${file}

    # Wait for all pipelines to finish
    echo "* Waiting for pending pipelines to finish..." >&2
    wait_until_pending_ppls_finish || return 1

    # Final update of active pipelines (necessary to finish moving
    # directories if requested)
    echo "* Final update of array of active pipelines..." >&2
    update_active_pipelines "${outd}" || return 1
    echo "" >&2

    # Check if there are active pipelines
    local num_active_pipelines=${#PIPELINE_COMMANDS[@]}
    if [ ${num_active_pipelines} -eq 0 ]; then
        echo "All pipelines were successfully executed" >&2
        echo "" >&2
    else
        echo "Warning: ${num_active_pipelines} pipelines did not complete execution" >&2
        echo "" >&2
    fi
}

########
check_pars()
{
    if [ ${f_given} -eq 0 ]; then
        echo "Error! -f parameter not given!" >&2
        exit 1
    else
        if [ ! -f ${file} ]; then
            echo "Error! file ${file} does not exist" >&2 
            exit 1
        fi
    fi

    if [ ${m_given} -eq 0 ]; then
        echo "Error! -m parameter not given!" >&2
        exit 1
    fi

    if [ ${o_given} -eq 1 ]; then
        if [ ! -d ${outd} ]; then
            echo "Error! output directory does not exist" >&2 
            exit 1
        fi
    fi
}

########

if [ $# -eq 0 ]; then
    print_desc
    exit 1
fi

read_pars $@ || exit 1

check_pars || exit 1

execute_batches || exit 1
