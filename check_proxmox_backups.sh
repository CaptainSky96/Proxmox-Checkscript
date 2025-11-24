#!/bin/bash

# Proxmox VM- & Backup-check
# detecting missing, outdated or orphaned VMs/Backups

# You need to run this as root or with sudo. commands like chattr needs root privileges

## DEFAULTS ##
## Declaring Arrays / Dictionaries ##
declare -r configfile=/etc/sysconfig/check_proxmox_backups.conf	# Config file for script
declare -a pbs_json_vms					# Backup Informations from all pbs Servers in Array variable
declare -A vms						# VM Maschines of productive proxmox
declare -A snaps					# Backup IDs of Store 1 + Store 21
declare -A snapcomment					# Backup Comment (Name of VM) of Store 1
declare -A snapprotected				# Check if Backup is protected
declare -A snapstore					# Backup Storage of each Backup ID
declare -i storename					# Store Name of Backup Storage
declare -a ignorepool					# Pools with comment 'nobackup'
declare -A pool_schedule				# Schedule of Pools
declare -A prune_backups				# Prune Backups of Pools with own scheduling
declare -A prune_storage				# Prune Backups of Storage with standard Retention Policy
declare -a pvecluster					# PVE Cluster Informations
declare -a pbstokens					# PBS Tokens for each PBS Server
declare -a pbsservers					# PBS Servers with URL
declare -a curl_pbs_maxtime				# Curl Timeout for each PBS Server
declare -i curl_pve_maxtime				# Curl Timeout for PVE Cluster
declare -a pve_json_vms					# PVE QEMU VM Informations
declare -A schedule_comment				# Comments of Pools
declare -a pve_json_pools				# PVE Pools Informations
declare -a pve_json_backups				# PVE Backup Informations
declare -a pve_json_storage				# PVE Storage Informations
declare -i verbose=0					# Verbose / Debug Mode
declare -i dte=$(date +%s)				# Date in seconds since epoch
declare -i yte=$(date -d "yesterday" +%s)	# Yesterday for checking uptime VM
declare -i ddays=$(date +%e)				# Day of month
declare -i start_script=$SECONDS			# Start time of script
declare -i MAX_THREAD_USAGE				# Maximum amount of multithreading
declare -a PIDS=()					# Array of process IDs for loops while sorting
declare -i nobackup					# Variable for 'nobackup' Tag
declare -i critical					# Variable for critical VMs in Tag

### FUNCTIONS ###

# Check orphaned backups

check_each_pbs_snap() {

	local snap_id="$1"

	debugmsg "bid: $snap_id - ${snapcomment[$snap_id]}"
	if ! grep -q $snap_id <<< "${!vms[@]}"
	then
		local getstorage=$(echo ${snapstore[$snap_id]})
		warn "BID: $snap_id - STORE: $getstorage - ${snapcomment[$snap_id]} - ORPHANED BACKUP WITH NO VM."
	else
		local vmhostname=$(echo ${vms[$snap_id]} | cut -d : -f1)
		local vmtags=$(echo ${vms[$snap_id]} | cut -d : -f5-)
		local newestbackup=$(echo "${snaps[$snap_id]}" | tail -1)
		local countbackups=$(wc -l <<< ${snaps[$snap_id]})
		local lastbakhostname=$(jq -rc ".data[] | select(.\"backup-id\"==\"$snap_id\") | select(.\"backup-time\"==$newestbackup) | \"\\(.\"comment\")\"" <<< "${pbs_json_vms[@]}")
		local allbakhostnames=(${snapcomment[$snap_id]})
		local oldbakhostnames=$(printf -- '%s\n' ${allbakhostnames[@]} | grep -Ev "$vmhostname" | tr '\n' ' ')
		local gettemplate=$(echo ${vms[$snap_id]} | cut -d : -f3)
		local getprotrected=${snapprotected[$snap_id]}
		local getstorage=$(echo ${snapstore[$snap_id]})

		if grep -q 'ignore' <<< "$vmtags"
		then
			debugmsg "Ignoring $snap_id"
			return
		fi

		if  [[ $gettemplate == 1 ]]
		then
			if [[ -z $getprotrected ]]
			then
				warn "BID: $snap_id - STORE: $getstorage - $vmhostname - TEMPLATE-VM HAS NO PROTECTED BACKUP!"
			else
				if (( $countbackups > 1 ))
				then
					debugmsg "BID: $snap_id - STORE: $getstorage - $vmhostname - multiple backups from template vm"
				else
					debugmsg "bid: $snap_id - STORE: $getstorage - protected backup timestamp: $(date -d @$getprotrected +'%F %T')"
				fi
			fi
			if [[ "$vmhostname" != "$lastbakhostname" ]] || [[ -n "$oldbakhostnames" ]]
			then
				warn "BID: $snap_id - STORE: $getstorage - $vmhostname - $lastbakhostname - TEMPLATE-VM HOSTNAME DIFFERS FROM BACKUP!"
			fi
		else
			if [[ "$vmhostname" != "$lastbakhostname" ]]
			then
				warn "BID: $snap_id - STORE: $getstorage - $vmhostname - $lastbakhostname - HOSTNAME HAS CHANGED! POSSIBLE DATALEAKING!"
			elif [[ -n "$oldbakhostnames" ]]
			then
				warn "BID: $snap_id - STORE: $getstorage - ${snapcomment[$snap_id]} - $oldbakhostnames - OLDER HOSTNAME DIFFERS! POSSIBLE DATALEAKING!"
			else
				debugmsg "bid: $snap_id - STORE: $getstorage - $lastbakhostname"
			fi
		fi
	fi
}

check_pbs_snaps() {

	verbosemsg "Check Backups of different hostnames, orphaned, templates, protected"
	local job_count=0
	for snap_id in ${!snaps[@]}
	do
		check_each_pbs_snap "$snap_id" &
		((job_count++))
		if (( job_count >= MAX_THREAD_USAGE ))
		then
			wait -n
			((job_count--))
		fi
	done
	wait
}

# check each pve qemu vm for existing backups, get timestamps from existing backups, compare timestamps and hostnames

check_each_pve_vm() {

	local pve_vm_id="$1"

	debugmsg "vmid: $pve_vm_id - ${vms[$pve_vm_id]}"

	## Filter informations
	# check if Name of VM equals Comment of Backup
	local vmname=$(echo ${vms[$pve_vm_id]} | cut -d : -f1)
	# check pools. if 'pool' has 'nobackup' as comment.
	local getpool=$(echo ${vms[$pve_vm_id]} | cut -d : -f2)
	# check if vm is a template
	local gettemplate=$(echo ${vms[$pve_vm_id]} | cut -d : -f3)
	# checks uptime if vm is jounger than 24h, skip missing backup
	local getuptime=$(echo ${vms[$pve_vm_id]} | cut -d : -f4)
	# check tags if 'nobackup' or 'ignore' tags defined for vm
	local gettags=$(echo ${vms[$pve_vm_id]} | cut -d : -f5-)
	# check if vm has protected backup
	local getprotrected=${snapprotected[$pve_vm_id]}
	# get backup schedule time
	local getschedule=$(echo "${pool_schedule[$getpool]}" | cut -d '|' -f3-)
	# get backup comment
	local schedulecmt=$(echo "${pool_schedule[$getpool]}" | cut -d '|' -f2)
	# get storage of backup
	local getstorage=$(echo "${pool_schedule[$getpool]}" | cut -d '|' -f1)

	if grep -qw 'ignore' <<< "$gettags"
	then
		debugmsg "Ignoring $pve_vm_id"
		return
	fi

	if [[ -z "$getstorage" ]]
	then
		debugmsg "VMID: $pve_vm_id - $vmname - NO BACKUP STORAGE DEFINED FOR THIS VM!"
		local getstorage="undefined"
	fi

	local base="VMID: $pve_vm_id - $vmname"

	if grep -qw 'nobackup' <<< "$gettags" || grep -qw "$getpool" <<< "${ignorepool[@]}"
	then
		local nobackup=1
		debugmsg "$base - nobackup Tag or in ignored Pool"
	fi

	if grep -qw 'critical' <<< "$gettags"
	then
		local critical=1
		debugmsg "$base - critical VM"
	fi

	# Check, if a Backup for VM exists
	if grep -q $pve_vm_id <<< "${!snaps[@]}"
	then
		debugmsg "$base - backup exists"
		# if backup for vm exists, get infos about oldest, newest and amount
		local oldestbackup=$(echo "${snaps[$pve_vm_id]}" | head -1)
		local newestbackup=$(echo "${snaps[$pve_vm_id]}" | tail -1)
		local countbackups=$(wc -l <<< ${snaps[$pve_vm_id]})
		# get diff between today and oldest / newest backup
		local oldbackupage=$(( (dte - oldestbackup) / 86400 ))
		local newbackupage=$(( (dte - newestbackup) / 86400 ))

		if [[ "$getstorage" == "undefined" ]]
		then
			debugmsg "$base - STORAGE TAKEN FROM EXISTING BACKUP."
			local getstorage=$(echo ${snapstore[$pve_vm_id]})
		fi

		# get time refer to schedule time
		# if schedule time is in format 'Mon 12:00', then get last occurrence of this time
		# else backup job runs daily

		if grep -qE '^[A-Za-z]{3} [0-9]{1,2}:[0-9]{2}$' <<< "$getschedule"
		then
			local scheduletime=$(date -d "last $getschedule" +%s)
			local scheduleage=$(( (dte - scheduletime) / 86400 ))
		else
			local scheduleage=0
		fi

		debugmsg "$base - Oldest Backup: $oldbackupage - Days:$(date -d @$oldestbackup +'%F %T')"
		debugmsg "$base - Newest Backup: $newbackupage - Days:$(date -d @$newestbackup +'%F %T')"
		debugmsg "$base - Amount of Backups: $countbackups"

		# check if VM has Tag: 'critical'. if not, use minbakage
		if ! (( $critical ))
		then
			scheduleage=$(( scheduleage + minbakage ))
		fi

		debugmsg "vmid: $pve_vm_id - scheduled age: $scheduleage"

		# Check newbakage and warn, if last newest backup is too old
		if [[ $gettemplate == 0 ]]
		then

			if (( $nobackup ))
			then
				if [[ -z $getprotrected ]]
				then
					if ! (( $critical ))
					then
						debugmsg "VMID: $pve_vm_id - $vmname - Store: $getstorage - Tags: $gettags - Pool: $getpool - Ignoring non critical Backup"
					else
						debugmsg "VMID: $pve_vm_id - $vmname - STORE: $getstorage - EXISTING BACKUP WITH TAG / WITHIN POOL 'NOBACKUP'"
					fi
				else
					debugmsg "VMID: $pve_vm_id - $vmname - Store: $getstorage - Tags: $gettags - Pool: $getpool - Ignoring Backup"
				fi	
			fi

			# get pruneage from pool or storage. if both exists, pool has priority
			# if none exists, define default retention of 7 days
			if [[ -n ${prune_backups[$getpool]} ]]
			then
				local pruneage=${prune_backups[$getpool]}
				local oldbakage=$(( ((dte - pruneage) / 86400) + 1 ))
				local retention=$(date -d @${prune_backups[$getpool]})
			elif [[ -n ${prune_storage[$getstorage]} ]]
			then
				local pruneage=${prune_storage[$getstorage]}
				local oldbakage=$(( ((dte - pruneage) / 86400) + 1 ))
				local retention=$(date -d @${prune_storage[$getstorage]})
			else
				local pruneage=$(( dte - 604800 )) # 7 days ago
				local oldbakage=7
				local retention=$(date -d @${pruneage})
			fi

			debugmsg "vmid: $pve_vm_id - Storage: $getstorage - Retention: $retention"
			debugmsg "vmid: $pve_vm_id - pruneage: $pruneage - oldbakage: $oldbakage"
			debugmsg "vmid: $pve_vm_id - oldbackupage: $oldbackupage"
			
			if (( $newbackupage > $scheduleage ))
			then
				if (( $nobackup ))
				then
					debugmsg "vmid: $pve_vm_id - $vmname - existing backup."
				else
					warn "VMID: $pve_vm_id - $vmname - LAST BACKUP WAS $newbackupage DAYS AGO!"
				fi
			fi

			if (( $oldbackupage > $oldbakage )) && [[ -z $getprotrected ]]
			then
				if (( $nobackup ))
				then
					debugmsg "VMID: $pve_vm_id - $vmname - OLDEST BACKUP WITH 'nobackup', $oldbackupage DAYS OLD. CHECK RETENTION POLICY!"
				else
					warn "VMID: $pve_vm_id - $vmname - OLDEST BACKUP IS $oldbackupage DAYS OLD. CHECK RETENTION POLICY!"
				fi
			fi
		else
			if [[ -z $getprotrected ]]
			then
				warn "VMID: $pve_vm_id - $vmname - TEMPLATE-VM HAS NO PROTECTED BACKUP."
			else
				debugmsg "vmid: $pve_vm_id - $vmname - pool:$getpool - tags:$gettags - template-vm:$(date -d @$getprotrected +'%F %T')"
			fi
		fi
	else
		local vmuptime=$(date -d "$getuptime seconds ago" +%s)
		if (( $nobackup ))
		then
			if [[ $gettemplate == 1 ]]
			then
				debugmsg "VMID: $pve_vm_id - $vmname - TEMPLATE-VM HAS NO BACKUP."
			else
				debugmsg "vmid: $pve_vm_id - $vmname - pool:$getpool - tags:$gettags - Ignoring Backup"
			fi
		elif (( $vmuptime > $yte ))
		then
			debugmsg "vmid: $pve_vm_id - $vmname - VM WAS CREATED TODAY."
		else
			warn "VMID: $pve_vm_id - $vmname - MISSING BACKUP!"
		fi
	fi
}

check_pve_vms() {
	verbosemsg "Check VMs of backups, tags, pools, protected templates"
	local job_count=0
	for pve_vm_id in ${!vms[@]}
	do
		check_each_pve_vm "$pve_vm_id" &
		((job_count++))
		if (( job_count >= MAX_THREAD_USAGE ))
		then
			wait -n
			((job_count--))
		fi
	done
	wait
}

# Sort all VMs in Array -- Pickup Pools with 'nobackup' as comment and sort them in array -- get schedule time per backup, poolbased
sort_pve_vms() {
	verbosemsg "Sorting PVE VMs in Array, checking pools..."

	# Get all VMs from PVE cluster
	for qemu_id in $(jq -rc ".data[] | select(.type==\"qemu\") | (.vmid)" <<< "$pve_json_vms" | sort -n)
	do
		vms[$qemu_id]=$(jq -rc ".data[] | select(.vmid==$qemu_id) | \"\\(.name):\\(.pool):\\(.template):\\(.uptime):\\(.tags)\"" <<< "$pve_json_vms") 
		debugmsg "qemu_id: $qemu_id - ${vms[$qemu_id]}"
	done
	verbosemsg "PVE: Amount of VMs: $(wc -w <<< ${!vms[@]})"

	# Get all Pools from PVE cluster
	# Pickup Pools with 'nobackup' as comment and sort them in array
	for pool_id in $(jq -rc '.data[] | select(.comment != null) | select(.comment | contains("nobackup")) | .poolid' <<< "$pve_json_pools" )
	do
		debugmsg "pool_id: $pool_id - Ignoring Pool"
		ignorepool+=("$pool_id")
	done

	# Get all Pools with enabled backups and sort them in Dictionary
	for pool_id in $(jq -rc '.data[] | select(.enabled==1) | .pool' <<< "$pve_json_backups")
	do
		pool_schedule[$pool_id]=$(jq -rc ".data[] | select(.pool==\"$pool_id\") | \"\\(.storage)|\\(.comment)|\\(.schedule)\"" <<< "$pve_json_backups")
		debugmsg "pool_id: $pool_id - ${pool_schedule[$pool_id]}"
	done
	
	# Get all Backup jobs with own prune scheduling and sort them in Dictionary
	for pool_id in $(jq -rc '.data[] | select(has("prune-backups")) | .pool' <<< "$pve_json_backups")
	do
		local poolprunetimer=()
		# jq -rc '.data[] | select(.pool=="697536-TS") | ."prune-backups" | to_entries | .[] | "\(.key)=\(.value)"'
		local poolprune=$(jq -rc ".data[] | select(.pool==\"$pool_id\") | .\"prune-backups\" | to_entries | .[] | \"\\(.key)=\\(.value)\"" <<< "$pve_json_backups")
		for pt in $poolprune # for prunetime in all existing prunetimes
		do
			[[ $pt =~ daily ]] && poolprunetimer+=("$(echo $pt | cut -d = -f2) days ago") # keep-daily
			[[ $pt =~ weekly ]] && poolprunetimer+=("$(echo $pt | cut -d = -f2) weeks ago") # keep-weekly
			[[ $pt =~ monthly ]] && poolprunetimer+=("$(echo $pt | cut -d = -f2) months ago") # keep-monthly
			[[ $pt =~ yearly ]] && poolprunetimer+=("$(echo $pt | cut -d = -f2) years ago") # keep-yearly
		done
		prune_backups[$pool_id]=$(date -d "${poolprunetimer[*]}" +%s)
		debugmsg "pool_id: $pool_id - Prune Backups: ${prune_backups[$pool_id]}"
	done

	# Get Backup Storages with the standard Retention Policy
	for storage in $(jq -rc '.data[] | select(.content=="backup") | .storage' <<< "$pve_json_storage")
	do
		local storageprunetimer=()
		local storageprune=$(jq -rc ".data[] | select(.storage==\"$storage\") | .\"prune-backups\"" <<< "$pve_json_storage")
		IFS=,
		for pt in $storageprune # for prunetime in all existing prunetimes
		do
			[[ $pt =~ daily ]] && storageprunetimer+=("$(echo $pt | cut -d = -f2) days ago") # keep-daily
			[[ $pt =~ weekly ]] && storageprunetimer+=("$(echo $pt | cut -d = -f2) weeks ago") # keep-weekly
			[[ $pt =~ monthly ]] && storageprunetimer+=("$(echo $pt | cut -d = -f2) months ago") # keep-monthly
			[[ $pt =~ yearly ]] && storageprunetimer+=("$(echo $pt | cut -d = -f2) years ago") # keep-yearly
		done
		IFS=$'\n'
		prune_storage[$storage]=$(date -d "${storageprunetimer[*]}" +%s)
		debugmsg "storage: $storage - Prune Backups: ${prune_storage[$storage]}"
	done
}

# Sort Backup infos

sort_pbs_backup() {
    local backup_id="$1"
    local tmpdir="$2"

    # Write each result to its own file
    jq -rc ".data[] | select(.\"backup-id\"==\"$backup_id\") | \"\\(.\"backup-time\")\"" <<< "${pbs_json_vms[@]}" | sort -n > "$tmpdir/snaps_$backup_id" && chattr +i "$tmpdir/snaps_$backup_id"
    jq -rc ".data[] | select(.\"backup-id\"==\"$backup_id\") | \"\\(.\"comment\")\"" <<< "${pbs_json_vms[@]}" | sort | uniq > "$tmpdir/snapcomment_$backup_id" && chattr +i "$tmpdir/snapcomment_$backup_id"
    jq -rc ".data[] | select(.\"backup-id\"==\"$backup_id\") | select(.\"protected\"==true) | \"\\(.\"backup-time\")\"" <<< "${pbs_json_vms[@]}" | sort -n > "$tmpdir/snapprotected_$backup_id" && chattr +i "$tmpdir/snapprotected_$backup_id"
    jq -rc ".data[] | select(.\"backup-id\"==\"$backup_id\") | \"\\(.\"storename\")\"" <<< "${pbs_json_vms[@]}" | sort | uniq > "$tmpdir/snapstore_$backup_id" && chattr +i "$tmpdir/snapstore_$backup_id"
}

sort_pbs_snaps() {
    verbosemsg "Sorting Backups in tmpfiles"
    local job_count=0
    local tmpdir=$(mktemp -d)

    for backup_id in $(jq -rc '.data[]."backup-id"' <<< "${pbs_json_vms[@]}" | sort -n | uniq)
    do
        sort_pbs_backup "$backup_id" "$tmpdir" &
        ((job_count++))
        if (( job_count >= MAX_THREAD_USAGE )); then
            wait -n
            ((job_count--))
        fi
		debugmsg "Processing Infos for backup_id: $backup_id"
    done
	wait

	verbosemsg "Sorting Backups in Array"
	# Now read results from temp files into arrays
    for backup_id in $(jq -rc '.data[]."backup-id"' <<< "${pbs_json_vms[@]}" | sort -n | uniq)
    do
        snaps[$backup_id]="$(< "$tmpdir/snaps_$backup_id")"
        snapcomment[$backup_id]="$(< "$tmpdir/snapcomment_$backup_id")"
        snapprotected[$backup_id]="$(< "$tmpdir/snapprotected_$backup_id")"
        snapstore[$backup_id]="$(< "$tmpdir/snapstore_$backup_id")"
        debugmsg "backup_id: $backup_id - store: ${snapstore[$backup_id]} - ${snapcomment[$backup_id]}"
    done
	chattr -i $tmpdir/*
    rm -rf "$tmpdir"
    verbosemsg "Amount of Backups: $(wc -w <<< ${!snaps[@]})"
}

# Get all PVE infos with pool
get_pve_cluster() {
	verbosemsg "Getting PVE: QEMU-VM information.."

	pve_url_vms="${pvecluster[0]}/cluster/resources"
	pve_url_pools="${pvecluster[0]}/pools"
	pve_url_backups="${pvecluster[0]}/cluster/backup"
	pve_url_storage="${pvecluster[0]}/storage"

	pve_json_vms=$(curl --max-time "$curl_pve_maxtime" -ksS -H "Authorization: PVEAPIToken=${pvecluster[1]}" --url "$pve_url_vms")
	pve_json_pools=$(curl --max-time "$curl_pve_maxtime" -ksS -H "Authorization: PVEAPIToken=${pvecluster[1]}" --url "$pve_url_pools")
	pve_json_backups=$(curl --max-time "$curl_pve_maxtime" -ksS -H "Authorization: PVEAPIToken=${pvecluster[1]}" --url "$pve_url_backups")
	pve_json_storage=$(curl --max-time "$curl_pve_maxtime" -ksS -H "Authorization: PVEAPIToken=${pvecluster[1]}" --url "$pve_url_storage")
}

# Get all Backup infos
get_pbs_server() {
	verbosemsg "Getting PBS: Backup Server information.."

	for pbs_srv in ${!pbsservers[@]}
	do
		local pbs_url="${pbsservers[$pbs_srv]}"
		local storename=$(echo "$pbs_url" | grep -Eo 'store[0-9]+')
		local pbs_json=$(curl --max-time "${curl_pbs_maxtime[$pbs_srv]}" -ksS -H "Authorization: PBSAPIToken=${pbstokens[$pbs_srv]}" --url "$pbs_url")
		pbs_json_vms+=($(echo $pbs_json | jq ".data[] += {\"storename\":\"$storename\"}"))
		debugmsg "URL: $pbs_url - Storage: $storename"
	done
	
}

# GETTING INFORMATIONS AND SORT THEM
get_and_sort() {

	local start_time duration

	# Get all PVE infos with pool
	start_time=$SECONDS
	get_pve_cluster
	duration=$(( SECONDS - start_time ))
	verbosemsg "Getting PVE Cluster information took: $duration seconds"

	# Get all Backup infos
	start_time=$SECONDS
	get_pbs_server
	duration=$(( SECONDS - start_time ))
	verbosemsg "Getting PBS Server information took: $duration seconds"

	# Sort all VMs in Array -- Pickup existing Pools with 'nobackup' as comment and sort them in array
	start_time=$SECONDS
	sort_pve_vms
	duration=$(( SECONDS - start_time ))
	verbosemsg "Sorting PVE VMs took: $duration seconds"

	# Sort Backup infos
	start_time=$SECONDS
	sort_pbs_snaps
	duration=$(( SECONDS - start_time ))
	verbosemsg "Sorting PBS Snapshots took: $duration seconds"

	# start check missing backups
	start_time=$SECONDS
	check_pve_vms
	duration=$(( SECONDS - start_time ))
	verbosemsg "Checking PVE VMs took: $duration seconds"

	start_time=$SECONDS
	check_pbs_snaps
	duration=$(( SECONDS - start_time ))
	verbosemsg "Checking PBS Snapshots took: $duration seconds"

	# overall duration
	duration=$(( SECONDS - start_script ))
	verbosemsg "Overall duration took: $duration seconds"
}

# Checking Entries before picking information through curl
check_entries() {

	if [[ -f $configfile ]]
	then
		source $configfile
	else
		 errormsg "$configfile: No config file. pls check path."
	fi

	if declare -f $cluster &>/dev/null
	then
		verbosemsg "$cluster: getting infos"
		debugmsg "$(declare -f $cluster)"
		$cluster
	else
		errormsg "$cluster: No cluster found. pls check Entries and $configfile."
	fi

	debugmsg "PVE: Cluster: ${pvecluster[@]}"
	debugmsg "PBS: Server: ${pbsservers[@]}"
	debugmsg "PBS: Tokens: ${pbstokens[@]}"
	debugmsg "curl_pve_maxtime: $curl_pve_maxtime"
	debugmsg "curl_pbs_maxtime: ${curl_pbs_maxtime[@]}"

	if [[ -z "${pvecluster[@]}" ]] || [[ -z "${pbsservers[@]}" ]] || [[ -z "${pbstokens[@]}" ]] || [[ -z "$curl_pve_maxtime" ]] || [[ -z "${curl_pbs_maxtime[@]}" ]]
	then
		errormsg "$cluster: $configfile - not usable or missing variable. pls check configfile."
	elif [[ ${#pbsservers[@]} -ne ${#curl_pbs_maxtime[@]} ]]
	then
		errormsg "$cluster: $configfile - amount of pbs servers: ${#pbsservers[@]} and ${#curl_pbs_maxtime[@]} not equal. pls check configfile."
	else
		get_and_sort
	fi

}

### Output Options ###
# WARN informations
warn() {
    # join all args into one string
    local msg
    msg="$(printf '%s ' "$@")"
    msg="${msg%" "}"                       # remove trailing space

    # replace newline and CR with single space, then squeeze multiple spaces
    msg="${msg//$'\r'/ }"
    msg="${msg//$'\n'/ }"
    # optional: squeeze multiple spaces (uses external command)
    msg="$(printf '%s' "$msg" | tr -s ' ')"

    echo -e "\nWARNING: $msg"
}

# ERROR MSG & EXIT SCRIPT
errormsg() {
	echo -e "ERROR: $@"
	exit 1
}

# for debugging purposes
jqmsg() {
	echo -e "$@"
}

# verbose logging: -v
verbosemsg() {
	[ $verbose -ge 1 ] && echo -e "VERBOSE: $@"
}
# debug logging: -vv+
debugmsg() {
	[ $verbose -ge 2 ] && echo -e "DEBUG: $@"
}

usage() { # for readable usage, function isn't written with auto indentation
echo "
Usage: $0 -c <clusterXX> [-h | -v]
 Options:
  -h : help
  -c : cluster, to use
  -v : 1x: verbose 2x: debug
 Examples:
 $0 -h
 $0 -c cluster01 -v
 $0 -c cluster02 -vv

 All configs should be under -> $configfile
"
exit 1
}

## main ##
# options #

while getopts "hvc:" opt
do
	case $opt in
		h)
			usage
			;;
		v)
			verbose=$(( $verbose + 1 ))
			;;
		c)
			cluster=${OPTARG}
			;;
	esac
done
shift $((OPTIND-1))

# start checking entries
if [[ -z $cluster ]]
then
	usage
else
	check_entries
fi