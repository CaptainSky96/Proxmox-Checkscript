<h1 align="left">Proxmox-Checkscript</h1>

<p align="left">This script checks (non-)existing QEMU VMs and give Information about the backup state.</p>

###

<h2 align="left">Requirements and how it works</h2>

<h3 align="left">Requirements</h3>

<p align="left">
  Install the package 'jq' (dnf | apt, doesnt matter).<br>
  You need an API Token for PVE and API Token(s) for each PBS.<br>
  The Users in PVE/PBS and its API should have Audit permissions in each section (Sys,VM,Pool,etc..).<br>
  In this script, you only can use the backup Retention from the Storage / Pool information in PVE. The Backup Retention in PBS is not implemented.<br>
  This script checks only QEMU VMs / Templates, not LXC Containers.<br>
  You need sudo permissions, because the script works with chattr.</p>

###

<h3 align="left">How it works</h3>

<p align="left">This Script gets the information of all QEMU VMs ans sorting them in Dictionaries.<br>
The ID, the Hostname, the pool and the given tags<br>
Also it gets all informations about the backup jobs, the pools and the storages.<br>
All Informations will be compared to the informations from PBS.<br>
Outputs WARNING IF:<br>
  - hostname changed ( compares all backup hostnames with current )<br>
  - Backup failed / doesn't exist / too old<br>
  - Template VM isn't protected<br><br>
Use it with crontab. Example:<br>
  35 15 * * * root /usr/local/bin/check_proxmox_backups.sh -c cluster01 |<br>
  /usr/bin/ifne mailx -s "Proxmox Backup Check: $(date +'\%F \%T')" 'yourmail@mail.com'
</p>

###

<p align="left">Options from Script:<br>
  - DEBUG mode<br>
  - VERBOSE mode<br>
  - configfile as 1 function for each PVE with X PBS.</p>

<p align="left">Options in PVE:<br>
  - Use the string: 'nobackup' as a tag for the VM or as comment in the pool, if the script should skip the Backupcheck for the specific VM / all VMs in specified pool.<br>
  - Use the sting: 'ignore' as a tag for the VM, if you want to completly ignore all warnings for the VM.</p>

###

<h2 align="left">Purpose</h2>

<p align="left">
If a company uses proxmox with multiple customers, there are problems in terms of data privacy.<br><br>
Example:<br>
customer A creates VM -> uses for 5 Days, has 3 Backups and deletes VM after 5 days.<br>
IMPORTANT: The backups will not be deleted by deleting the VM.<br>
customer B creates VM -> gets same VMID as customer A had, possibility of restoring Backups from customer A.<br><br>
To encounter this issue ( not solving it, im not a developer, im an admin ),<br>this script gives per crontab all informations needed for checking Backups and changed hostnames.<br>


<h4 align="left">About me</h4>

###

<p align="left">My name is Sky and I'm an admin, from Germany</p>
<p align="left">✨ Trying things that i couldnt find on the www<br>📚 Trying and learning while working<br>🎯 Goals: Having fun while coding<br>🎲 Fun fact: I like trains</p>

###

<h4 align="left">The code is written in <img src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/bash/bash-original.svg" height="40" alt="bash logo"/></h4>

###
