# *- bash -*

########
init_bash_shebang_var()
{
    echo "#!${BASH}"
}

########
exclude_readonly_vars()
{
    $AWK -F "=" 'BEGIN{
                         readonlyvars["BASHOPTS"]=1
                         readonlyvars["BASH_VERSINFO"]=1
                         readonlyvars["EUID"]=1
                         readonlyvars["PPID"]=1
                         readonlyvars["SHELLOPTS"]=1
                         readonlyvars["UID"]=1
                        }
                        {
                         if(!($1 in readonlyvars)) printf"%s\n",$0
                        }'
}

########
exclude_bashisms()
{
    $AWK '{if(index($1,"=(")==0) printf"%s\n",$0}'
}

########
write_functions()
{
    for f in `$AWK '{if(index($1,"()")!=0) printf"%s\n",$1}' $0`; do
        sed -n /^$f/,/^}/p $0
    done
}

########
create_script()
{
    # Init variables
    local_name=$1
    local_command=$2
    local_script_pars=$3

    # Save previous file (if any)
    if [ -f ${local_name} ]; then
        cp ${local_name} ${local_name}.previous
    fi
    
    # Write bash shebang
    local_BASH_SHEBANG=`init_bash_shebang_var`
    echo ${local_BASH_SHEBANG} > ${local_name}

    # Write SLURM commands
    echo "#SBATCH --job-name=${local_command}" >> ${local_name}
    echo "#SBATCH --output=${local_name}.slurm_out" >> ${local_name}

    # Write environment variables
    set | exclude_readonly_vars | exclude_bashisms >> ${local_name}

    # Write functions if necessary
    $GREP "()" ${local_name} -A1 | $GREP "{" > /dev/null || write_functions >> ${local_name}
    
    # Write command to be executed
    echo "${local_command} ${local_script_pars}" >> ${local_name}

    # Give execution permission
    chmod u+x ${local_name}

    # Archive script with date info
    curr_date=`date '+%Y_%m_%d'`
    cp ${local_name} ${local_name}.${curr_date}
}

########
get_dependency_opt()
{
    local_jobdeps=$1

    if [ -z "${local_jobdeps}" ]; then
        echo ""
    else
        echo "--dependency=afterok${local_jobdeps}"
    fi
}

########
launch()
{
    local_file=$1
    local_cpus=$2
    local_mem=$3
    local_time=$4
    local_jobdeps=$5
    local_outvar=$6
    
    if [ -z "${SBATCH}" ]; then
        $local_file
        eval "${outvar}=\"\""
    else
        dependency_opt=`get_dependency_opt "${local_jobdeps}"`
        local_jid=$($SBATCH --cpus-per-task=${local_cpus} --mem=${local_mem} --time ${local_time} --parsable ${dependency_opt} ${local_file})
        eval "${local_outvar}='${local_jid}'"
    fi
}

########
entry_is_ok()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{if(NF>=4) print"yes\n"; else print"no\n"}'
}

########
extract_stepname_from_entry()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{print $1}'
}

########
extract_cpus_from_entry()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{print $2}'
}

########
extract_mem_from_entry()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{print $3}'
}

########
extract_time_from_entry()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{print $4}'
}

########
extract_jobdeps_spec_from_entry()
{
    local_entry=$1
    echo "${local_entry}" | $AWK '{print substr($5,9)}'
}

########
get_step_dirname()
{
    local_dirname=$1
    local_stepname=$2
    echo ${local_dirname}/${local_stepname}
}

########
reset_outdir_for_step() 
{
    local_dirname=$1
    local_stepname=$2
    local_outd=`get_step_dirname ${local_dirname} ${local_stepname}`

    if [ -d ${local_outd} ]; then
        echo "Warning: ${local_stepname} output directory already exists but analysis was not finished, directory content will be removed">&2
        rm -rf ${local_outd}/* || { echo "Error! could not clear output directory" >&2; return 1; }
    else
        mkdir ${local_outd} || { echo "Error! cannot create output directory" >&2; return 1; }
    fi
}

########
get_step_status()
{
    local_dirname=$1
    local_stepname=$2
    local_stepdirname=`get_step_dirname ${local_dirname} ${local_stepname}`
    
    if [ -d ${local_stepdirname} ]; then
        if [ -f ${local_stepdirname}/finished ]; then
            echo "FINISHED"
        else
            echo "UNFINISHED"
        fi
    else
        echo "TO-DO"
    fi
}

##################
# ANALYSYS STEPS #
##################

########
execute_manta_somatic()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_tumorbam=$3
    local_outd=$4
    local_cpus=$5
    local_step_outd=`get_step_dirname ${local_outd} manta_somatic`

    # Activate conda environment
    conda activate manta
    
    # Configure Manta
    configManta.py --normalBam ${local_normalbam} --tumorBam ${local_tumorbam} --referenceFasta ${local_ref} --runDir ${local_step_outd} > ${local_step_outd}/configManta.log 2>&1 || exit 1

    # Execute Manta
    ${local_step_outd}/runWorkflow.py -m local -j ${local_cpus} > ${local_step_outd}/runWorkflow.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_strelka_somatic()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_tumorbam=$3
    local_outd=$4
    local_cpus=$5
    local_step_outd=`get_step_dirname ${local_outd} strelka_somatic`

    # Activate conda environment
    conda activate strelka

    # Configure Strelka
    configureStrelkaSomaticWorkflow.py --normalBam ${local_normalbam} --tumorBam ${local_tumorbam} --referenceFasta ${local_ref} --runDir ${local_step_outd} > ${local_step_outd}/configureStrelkaSomaticWorkflow.log 2>&1 || exit 1

    # Execute Strelka
    ${local_step_outd}/runWorkflow.py -m local -j ${local_cpus} > ${local_step_outd}/runWorkflow.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_msisensor()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_tumorbam=$3
    local_outd=$4
    local_cpus=$5
    local_step_outd=`get_step_dirname ${local_outd} msisensor`
    
    # Activate conda environment
    conda activate msisensor

    # Create homopolymer and microsatellites file
    msisensor scan -d ${local_ref} -o ${local_step_outd}/msisensor.list > ${local_step_outd}/msisensor_scan.log 2>&1 || exit 1

    # Run MSIsensor analysis
    msisensor msi -d ${local_step_outd}/msisensor.list -n ${local_normalbam} -t ${local_tumorbam} -o ${local_step_outd}/output -l 1 -q 1 -b ${local_cpus} > ${local_step_outd}/msisensor_msi.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate
    
    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_platypus_germline_conda()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_outd=$3
    local_step_outd=`get_step_dirname ${local_outd} platypus_germline_conda`

    # Activate conda environment
    conda activate platypus

    # Run Platypus
    Platypus.py callVariants --bamFiles=${local_normalbam} --refFile=${local_ref} --output=${local_step_outd}/output.vcf --verbosity=1 > ${local_step_outd}/platypus.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished        
}

########
execute_platypus_germline_local()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_outd=$3
    local_step_outd=`get_step_dirname ${local_outd} platypus_germline_local`
    
    # Run Platypus
    python ${PLATYPUS_BUILD_DIR}/bin/Platypus.py callVariants --bamFiles=${local_normalbam} --refFile=${local_ref} --output=${local_step_outd}/output.vcf --verbosity=1 > ${local_step_outd}/platypus.log 2>&1 || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished    
}

########
execute_platypus_germline()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_outd=$3

    if [ -z "${PLATYPUS_BUILD_DIR}" ]; then
        execute_platypus_germline_conda ${local_ref} ${local_normalbam} ${local_outd}
    else
        execute_platypus_germline_local ${local_ref} ${local_normalbam} ${local_outd}
    fi
}

########
execute_cnvkit()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_tumorbam=$3
    local_outd=$4
    local_cpus=$5
    local_step_outd=`get_step_dirname ${local_outd} cnvkit`
    
    # Activate conda environment
    conda activate cnvkit

    # Run cnvkit
    cnvkit.py batch ${local_tumorbam} -n ${local_normalbam} -m wgs -f ${local_ref}  -d ${local_step_outd} -p ${local_cpus} > ${local_step_outd}/cnvkit.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_wisecondorx()
{
    # Initialize variables
    local_wcref=$1
    local_tumorbam=$2
    local_outd=$3
    local_cpus=$4
    local_step_outd=`get_step_dirname ${local_outd} cnvkit`
    
    # Activate conda environment
    conda activate wisecondorx

    # Convert tumor bam file into npz
    BINSIZE=5000
    WisecondorX convert ${local_tumorbam} ${local_step_outd}/tumor.npz --binsize $BINSIZE > ${local_step_outd}/wisecondorx_convert.log 2>&1 || exit 1
    
    # Use WisecondorX for prediction
    WisecondorX predict ${local_step_outd}/tumor.npz ${local_wcref} ${local_step_outd}/out > ${local_step_outd}/wisecondorx_predict.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_ascatngs()
{
    # Initialize variables
    local_ref=$1
    local_normalbam=$2
    local_tumorbam=$3
    local_gender=$4
    local_malesexchr=$5
    local_snpgccorr=$6
    local_outd=$7
    local_cpus=$8
    local_step_outd=`get_step_dirname ${local_outd} ascatngs`
    
    # Activate conda environment
    conda activate ascatngs

    # Run cnvkit
    ascat.pl -n ${local_normalbam} -t ${local_tumbam} -r ${local_ref} -sg ${local_snpgccorr} -pr WGS -g ${local_gender} -gc ${local_malesexchr} -cpus ${local_cpus} > ${local_step_outd}/ascat.log 2>&1 || exit 1

    # Deactivate conda environment
    conda deactivate

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_download_ega_norm_bam()
{
    # Initialize variables
    local_normalbam=$1
    local_egaid_normalbam=$2
    local_egastr=$3
    local_egacred=$4
    local_outd=$5
    local_step_outd=`get_step_dirname ${local_outd} download_ega_norm_bam`

    # Download file
    ${PYEGA_BUILD_DIR}/pyega3 -c ${local_egastr} -cf ${local_egacred} fetch ${local_egaid_normalbam} ${local_normalbam} > ${local_step_outd}/pyega3.log 2>&1 || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_download_ega_tum_bam()
{
    # Initialize variables
    local_tumorbam=$1
    local_egaid_tumorbam=$2
    local_egastr=$3
    local_egacred=$4
    local_outd=$5
    local_step_outd=`get_step_dirname ${local_outd} download_ega_tum_bam`

    # Download file
    ${PYEGA_BUILD_DIR}/pyega3 -c ${local_egastr} -cf ${local_egacred} fetch ${local_egaid_tumorbam} ${local_tumorbam} > ${local_step_outd}/pyega3.log 2>&1 || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_index_norm_bam()
{
    # Initialize variables
    local_normalbam=$1
    local_outd=$2
    local_step_outd=`get_step_dirname ${local_outd} index_norm_bam`

    # Index normal bam file if necessary
    if [ ! -f ${local_normalbam}.bai ]; then

        # Activate conda environment
        conda activate base

        # Execute samtools
        samtools index ${local_normalbam} > ${local_step_outd}/samtools.log 2>&1 || exit 1

        # Deactivate conda environment
        conda deactivate
    fi
    
    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_sort_norm_bam()
{
    # Initialize variables
    local_normalbam=$1
    local_outd=$2
    local_step_outd=`get_step_dirname ${local_outd} sort_norm_bam`

    # Activate conda environment
    conda activate base

    # Execute samtools
    samtools sort ${local_normalbam} > ${local_step_outd}/sorted.bam 2> ${local_step_outd}/samtools.log || exit 1
    
    # Deactivate conda environment
    conda deactivate

    # Replace initial bam file by the sorted one
    mv ${local_step_outd}/sorted.bam ${local_normalbam} 2> ${local_step_outd}/mv.log || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_sort_tum_bam()
{
    # Initialize variables
    local_tumorbam=$1
    local_outd=$2
    local_step_outd=`get_step_dirname ${local_outd} sort_tum_bam`

    # Activate conda environment
    conda activate base

    # Execute samtools
    samtools sort ${local_tumorbam} > ${local_step_outd}/sorted.bam 2> ${local_step_outd}/samtools.log || exit 1
    
    # Deactivate conda environment
    conda deactivate

    # Replace initial bam file by the sorted one
    mv ${local_step_outd}/sorted.bam ${local_tumorbam} 2> ${local_step_outd}/mv.log || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_index_tum_bam()
{
    # Initialize variables
    local_tumorbam=$1
    local_outd=$2
    local_step_outd=`get_step_dirname ${local_outd} index_tum_bam`

    # Index tumor bam file if necessary
    if [ ! -f ${local_tumorbam}.bai ]; then

        # Activate conda environment
        conda activate base

        # Execute samtools
        samtools index ${local_tumorbam} > ${local_step_outd}/samtools.log 2>&1 || exit 1

        # Deactivate conda environment
        conda deactivate
    fi
    
    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}

########
execute_delete_bam_files()
{
    # Initialize variables
    local_normalbam=$1
    local_tumorbam=$2
    local_outd=$3
    local_step_outd=`get_step_dirname ${local_outd} delete_bam_files`

    # Delete normal bam file
    rm ${local_normalbam} > ${local_step_outd}/rm_norm.log 2>&1 || exit 1
    
    # Delete tumor bam file
    rm ${local_tumorbam} > ${local_step_outd}/rm_tum.log 2>&1 || exit 1

    # Create file indicating that execution was finished
    touch ${local_step_outd}/finished
}