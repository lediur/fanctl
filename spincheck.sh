#!/usr/bin/bash
# spincheck.sh, logs fan and temperature data
VERSION="2020-06-17"
# Run as superuser. See notes at end.

# Creates logfile and sends all stdout and stderr to the log,
# leaving the previous contents in place. If you want to append to existing log,
# add '-a' to the tee command.
# Change to your desired log location/name:
# LOG=/mnt/MyPool/MyDataSet/MyDirectory/spincheck.log
LOG=/tmp/fanctl_spincheck.log
exec > >(tee -i $LOG) 2>&1

SP=33.57 #  Setpoint mean drive temp (C), for information only

# Path to ipmitool.  If you're doing VM
# you may need to add (after first quote) the following to
# remotely execute commands.
#  -H <hostname/ip> -U <username> -P <password>
IPMITOOL="/usr/bin/ipmitool"

##############################################
# function get_disk_name
# Get disk name from current LINE of DEVLIST
##############################################
# The awk statement works by taking $LINE as input,
# setting '(' as a _F_ield separator and taking the second field it separates
# (ie after the separator), passing that to another awk that uses
# ',' as a separator, and taking the first field (ie before the separator).
# In other words, everything between '(' and ',' is kept.

# camcontrol output for disks on HBA seems to change  every version,
# so need 2 options to get ada/da disk name.
function get_disk_name() {
    if [[ $LINE == *"(p"* ]]; then # for (pass#,[a]da#)
        DEVID=$(echo $LINE | awk -F ',' '{print $2}' | awk -F ')' '{print$1}')
    else # for ([a]da#,pass#)
        DEVID=$(echo $LINE | awk -F '(' '{print $2}' | awk -F ',' '{print$1}')
    fi
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header() {
    DATE=$(date +"%A, %b %d")
    printf "\n%s \n" "$DATE"
    echo -n "          "
    while read LINE; do
        get_disk_name
        printf "%-5s" $DEVID
    done <<<"$DEVLIST" # while statement works on DEVLIST
    printf "%4s %5s %5s %3s %5s %5s %5s %5s %5s %5s %5s %-7s" "Tmax" "Tmean" "ERRc" "CPU" "FAN1" "FAN2" "FAN3" "FAN4" "FANA" "Fan%0" "Fan%1" "MODE"
}

#################################################
# function manage_data: Read, process, print data
#################################################
function manage_data() {
    Tmean=$(echo "scale=3; $Tsum / $i" | bc)
    ERRc=$(echo "scale=2; $Tmean - $SP" | bc)
    # Read duty cycle, convert to decimal.
    # May need to disable these 3 lines as some boards apparently return
    # incorrect data. In that case just assume $DUTY hasn't changed.
    DUTY0=$($IPMITOOL raw 0x30 0x70 0x66 0 0) # in hex
    DUTY0=$((0x$(echo $DUTY0)))               # strip leading space and decimate
    DUTY1=$($IPMITOOL raw 0x30 0x70 0x66 0 1) # in hex
    DUTY1=$((0x$(echo $DUTY1)))               # strip leading space and decimate
    # Read fan mode, convert to decimal.
    MODE=$($IPMITOOL raw 0x30 0x45 0) # in hex
    MODE=$((0x$(echo $MODE)))         # strip leading space and decimate
    # Text for mode
    case $MODE in
    0) MODEt="Standard" ;;
    4) MODEt="HeavyIO" ;;
    2) MODEt="Optimal" ;;
    1) MODEt="Full" ;;
    esac
    # Get reported fan speed in RPM.
    # Get reported fan speed in RPM from sensor data repository.
    # Takes the pertinent FAN line, then a number with 3 to 5
    # consecutive digits
    SDR=$($IPMITOOL sdr)
    RPM_FAN1=$(echo "$SDR" | grep "FAN1" | grep -Eo '[0-9]{3,5}')
    RPM_FAN2=$(echo "$SDR" | grep "FAN2" | grep -Eo '[0-9]{3,5}')
    RPM_FAN3=$(echo "$SDR" | grep "FAN3" | grep -Eo '[0-9]{3,5}')
    RPM_FAN4=$(echo "$SDR" | grep "FAN4" | grep -Eo '[0-9]{3,5}')
    RPM_FANA=$(echo "$SDR" | grep "FANA" | grep -Eo '[0-9]{3,5}')
    # Get    # print current Tmax, Tmean
    printf "^%-3d %5.2f" $Tmax $Tmean
}

##############################################
# function DRIVES_check
# Print time on new log line.
# Go through each drive, getting and printing
# status and temp, then call function manage_data.
##############################################
function DRIVES_check() {
    echo # start new line
    TIME=$(date "+%H:%M:%S")
    echo -n "$TIME  "
    Tmax=0
    Tsum=0 # initialize drive temps for new loop through drives
    i=0    # count number of spinning drives
    while read LINE; do
        get_disk_name
        /usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" >/var/tempfile
        RETURN=$? # have to preserve return value or it changes
        BIT0=$(($RETURN & 1))
        BIT1=$(($RETURN & 2))
        if [ $BIT0 -eq 0 ]; then
            if [ $BIT1 -eq 0 ]; then
                STATUS="*" # spinning
            else           # drive found but no response, probably standby
                STATUS="_"
            fi
        else # smartctl returns 1 (00000001) for missing drive
            STATUS="?"
        fi

        TEMP=""
        # Update temperatures each drive; spinners only
        if [ "$STATUS" == "*" ]; then
            # Taking 10th space-delimited field for most SATA:
            if grep -Fq "Temperature_Celsius" /var/tempfile; then
                TEMP=$(cat /var/tempfile | grep "Temperature_Celsius" | awk '{print $10}')
            # Else assume SAS, their output is:
            #     Transport protocol: SAS (SPL-3) . . .
            #     Current Drive Temperature: 45 C
            else
                TEMP=$(cat /var/tempfile | grep "Drive Temperature" | awk '{print $4}')
            fi
            let "Tsum += $TEMP"
            if [[ $TEMP > $Tmax ]]; then Tmax=$TEMP; fi
            let "i += 1"
        fi
        printf "%s%-2d  " "$STATUS" $TEMP
    done <<<"$DEVLIST"
    manage_data # manage data function
}

#####################################################
# All this happens only at the beginning
# Initializing values, list of drives, print header
#####################################################

# Check if CPU Temp is available via sysctl (will likely fail in a VM)
CPU_TEMP_SYSCTL=$(($(sysctl -a | grep dev.cpu.0.temperature | wc -l) > 0))
if [[ $CPU_TEMP_SYSCTL == 1 ]]; then
    CORES=$(($(sysctl -n hw.ncpu) - 1))
fi

echo "How many whole minutes do you want between spin checks?"
read T
SEC=$(bc <<<"$T*60") # bc is a calculator
# Get list of drives
DEVLIST1=$(/sbin/camcontrol devlist)
# Remove lines with non-spinning devices; edit as needed
# You could use another strategy, e.g., find something in the camcontrol devlist
# output that is unique to the drives you want, for instance only WDC drives:
# if [[ $LINE != *"WDC"* ]] . . .
DEVLIST="$(echo "$DEVLIST1" | sed '/KINGSTON/d;/ADATA/d;/SanDisk/d;/OCZ/d;/LSI/d;/EXP/d;/INTEL/d;/TDKMedia/d;/SSD/d;/VMware/d;/Enclosure/d;/Card/d;/Flash/d')"
DEVCOUNT=$(echo "$DEVLIST" | wc -l)
printf "\n%s\n%s\n%s\n" "NOTE ABOUT DUTY CYCLE (Fan%0 and Fan%1):" \
    "Some boards apparently report incorrect duty cycle, and can" \
    "report duty cycle for zone 1 when that zone does not exist."

# Before starting, go through the drives to report if
# smartctl return value indicates a problem (>2).
# Use -a so that all return values are available.
while read LINE; do
    get_disk_name
    /usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" >/var/tempfile
    if [ $? -gt 2 ]; then
        printf "\n"
        printf "*******************************************************\n"
        printf "* WARNING - Drive %-4s has a record of past errors,   *\n" $DEVID
        printf "* is currently failing, or is not communicating well. *\n"
        printf "* Use smartctl to examine the condition of this drive *\n"
        printf "* and conduct tests. Status symbol for the drive may  *\n"
        printf "* be incorrect (but probably not).                    *\n"
        printf "*******************************************************\n"
    fi
done <<<"$DEVLIST"

printf "\n%s %36s %s \n" "Key to drive status symbols:  * spinning;  _ standby;  ? unknown" "Version" $VERSION
print_header

###########################################
# Main loop through drives every T minutes
###########################################
while [ 1 ]; do
    # Print header every quarter day.  Expression removes any
    # leading 0 so it is not seen as octal
    HM=$(date +%k%M)
    HM=$(expr $HM + 0)
    R=$((HM % 600)) # remainder after dividing by 6 hours
    if (($R < $T)); then print_header; fi
    Tmax=0
    Tsum=0 # initialize drive temps for new loop through drives
    DRIVES_check

    if [[ $CPU_TEMP_SYSCTL == 1 ]]; then
        # Find hottest CPU core
        MAX_CORE_TEMP=0
        for CORE in $(seq 0 $CORES); do
            CORE_TEMP="$(sysctl -n dev.cpu.${CORE}.temperature | awk -F '.' '{print$1}')"
            if [[ $CORE_TEMP -gt $MAX_CORE_TEMP ]]; then MAX_CORE_TEMP=$CORE_TEMP; fi
        done
        CPU_TEMP=$MAX_CORE_TEMP
    else
        CPU_TEMP=$($IPMITOOL sensor get "CPU Temp" | awk '/Sensor Reading/ {print $4}')
    fi

    # Print data.  If a fan doesn't exist, RPM value will be null.  These expressions
    # substitute a value "---" if null so printing is not messed up.  Duty cycle may be
    # reported incorrectly by boards and they can report duty for zone 1 even if there
    # is no such zone.
    printf "%6.2f %3d %5s %5s %5s %5s %5s %5d %5d %-7s" $ERRc $CPU_TEMP "${RPM_FAN1:----}" "${RPM_FAN2:----}" "${RPM_FAN3:----}" "${RPM_FAN4:----}" "${RPM_FANA:----}" $DUTY0 $DUTY1 $MODEt

    sleep $(($T * 60)) # seconds between runs
done

# Logs:
#   - disk status (spinning or standby)
#   - disk temperature (Celsius) if spinning
#   - max and mean disk temperature
#   - current 'error' of Tmean from setpoint (for information only)
#   - CPU temperature
#   - RPM for FAN1-4 and FANA
#   - duty cycle for fan zones 0 and 1
#   - fan mode

# Includes disks on motherboard and on HBA.
# Uses joeschmuck's smartctl method (returns 0 if spinning, 2 in standby)
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
# Other method (camcontrol cmd -a) doesn't work with HBA
