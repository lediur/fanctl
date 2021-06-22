#!/usr/bin/bash

# spinpid2.sh for dual fan zones.
VERSION="2021-03-12"
# Run as superuser. See notes at end.

##############################################
#
#  Settings
#
##############################################

IPMITOOL="/usr/bin/ipmitool"
TEMPTOOL="/opt/fanctl/temptool.sh"
USE_AMBIENT_TEMP=0

#################  OUTPUT SETTINGS ################

# Change to your desired log location/name:
LOG=/tmp/fanctl_spinpid2z.log

# CPU output sent to a separate log for interim cycles
# It can get big so turn off after testing. 1 = log cpu, anything else = don't log cpu
CPU_LOG_YES=0

# Path/name of cpu log
# CPU_LOG=/mnt/MyPool/MyDataSet/MyDirectory/cpu.log
CPU_LOG=/tmp/fanctl_spinpid2z_cpu.log

#################  FAN SETTINGS ################

# Supermicro says:
# Zone 0 - CPU/System fans, headers with number (e.g., FAN1, FAN2, etc.)
# Zone 1 - Peripheral fans, headers with letter (e.g., FANA, FANB, etc.)
# Some want the reverse (i.e, drive cooling fans on headers FAN1-4 and
# CPU fan on FANA), so that's the default.  But you can switch to SM way.
ZONE_CPU=1
ZONE_PER=0

# Set min and max duty cycle to avoid stalling or zombie apocalypse
DUTY_PER_MIN=30
DUTY_PER_MAX=100
DUTY_CPU_MIN=30
DUTY_CPU_MAX=100

# Your measured fan RPMs at 30% duty cycle and 100% duty cycle
# RPM_CPU is for FANA if ZONE_CPU=1 or FAN1 if ZONE_CPU=0
# RPM_PER is for the other fan.
# RPM_CPU_30=400   # My system
# RPM_CPU_MAX=1500
# RPM_PER_30=600
# RPM_PER_MAX=1800
RPM_CPU_30=600 # Your system
RPM_CPU_MAX=1950
RPM_PER_30=600
RPM_PER_MAX=2150

#################  DRIVE SETTINGS ################

SP=37 #  Setpoint mean drive temperature (C)

#  Time interval for checking drives (minutes).  Drives change
#  temperature slowly; 5 minutes is probably frequent enough.
DRIVE_T=1
# Tunable constants for drive control (see comments at end of script)
Kp=4  #  Proportional tunable constant
Kd=40 #  Derivative tunable constant

# Ambient temperature difference (i.e. the ideal difference between a drive temp
# and ambient temperature). Determine empirically.
AMBIENT_COEFF=12 

#################  CPU SETTINGS ################

#  Time interval for checking CPU (seconds).  1 to 12 may be appropriate
CPU_T=5

#  Reference temperature (C) for scaling CPU_DUTY (NOT a setpoint).
#  At and below this temperature, CPU will demand minimum
#  duty cycle (DUTY_CPU_MIN).
CPU_REF=35 # Integer only!
#  Scalar for scaling CPU_DUTY.
#  CPU will demand this number of percentage points in additional
#  duty cycle for each degree of temperature above CPU_REF.
CPU_SCALE=3 # Integer only!

################## Load .env file ###############

set -a
source <(cat .env | sed -e '/^#/d;/^\s*$/d' -e "s/'/'\\\''/g" -e "s/=\(.*\)/='\1'/g")
set +a

################## Setup logging ################

# Where do you want output to go?  Comment/uncomment (#) to select.  First sends output to the log file AND to screen/console.  Second sends it only to the log file, so no feedback if running manually.  In the first, if you want to append to existing log, add '-a' to the tee command.
exec > >(tee -i $LOG) 2>&1 # Log + console
# exec &> $LOG						# Log only

##############################################
# function get_disk_name
# Get disk name from current LINE of DEVLIST
##############################################
# The awk statement works by taking $LINE as input,
# setting '(' as a _F_ield separator and taking the second field it separates
# (ie after the separator), passing that to another awk that uses
# ',' as a separator, and taking the first field (ie before the separator).
# In other words, everything between '(' and ',' is kept.

# camcontrol output for disks on HBA seems to change every version,
# so need 2 options to get ada/da disk name.
function get_disk_name() {
    # echo "Line: $LINE"
    DEVID=$(echo "$LINE" | awk '{print $1}')
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header() {
    DATE=$(date +"%A, %b %d")
    SPACES=$((DEVCOUNT * 5 + 42)) # 5 spaces per drive
    printf "\n%-*s %3s %16s %29s \n" "$SPACES" "$DATE" "CPU" "New_Fan%" "New_RPM_____________________"
    echo -n "          "
    while read -r LINE; do
        get_disk_name
        printf "%-5s" "$DEVID"
    done <<<"$DEVLIST" # while statement works on DEVLIST
    printf "%4s %5s %6s %6s %6s %3s %-7s %s %-4s %5s %5s %5s %5s %5s" "Tmax" "Tmean" "ERRc" "P" "D" "TEMP" "MODE" "CPU" "PER" "FANA" "FAN1" "FAN2" "FAN3" "FAN4"
}

#################################################
# function read_fan_data
#################################################
function read_fan_data() {
    # Read duty cycles, convert to decimal.  This is not used by
    # default because some boards report incorrect data.  Instead,
    # the script will assume the duty cycles are what was last set.
    # Still, we try it the first time so we try to start with fans as they are.
    # If it seems to work for you, just remove the if and fi lines
    #ztest#	if [ $FIRST_TIME == 1 ] ; then
    #ztest#		DUTY_CPU=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_CPU) # in hex with leading space
    #ztest#		DUTY_CPU=$((0x$(echo $DUTY_CPU)))  # strip leading space and decimalize
    #ztest#		DUTY_PER=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_PER)
    #ztest#		DUTY_PER=$((0x$(echo $DUTY_PER)))
    #ztest#	fi

    # Read fan mode, convert to decimal, get text equivalent.
    MODE=$($IPMITOOL raw 0x30 0x45 0) # in hex with leading space
    MODE=$((0x$(echo $MODE)))         # strip leading space and decimalize
    # Text for mode
    case $MODE in
    0) MODEt="Standard" ;;
    1) MODEt="Full" ;;
    2) MODEt="Optimal" ;;
    4) MODEt="HeavyIO" ;;
    esac

    # Get reported fan speed in RPM from sensor data repository.
    # Takes the pertinent FAN line, then 3 to 5 consecutive digits
    SDR=$($IPMITOOL sdr)
    FAN1=$(echo "$SDR" | grep "FAN1" | grep -Eo '[0-9]{3,5}')
    FAN2=$(echo "$SDR" | grep "FAN2" | grep -Eo '[0-9]{3,5}')
    FAN3=$(echo "$SDR" | grep "FAN3" | grep -Eo '[0-9]{3,5}')
    FAN4=$(echo "$SDR" | grep "FAN4" | grep -Eo '[0-9]{3,5}')
    FAN5=$(echo "$SDR" | grep "FAN5" | grep -Eo '[0-9]{3,5}')
    FAN6=$(echo "$SDR" | grep "FAN6" | grep -Eo '[0-9]{3,5}')
    FANA=$(echo "$SDR" | grep "FANA" | grep -Eo '[0-9]{3,5}')
    FANB=$(echo "$SDR" | grep "FANB" | grep -Eo '[0-9]{3,5}')
}

##############################################
# function CPU_check_adjust
# Get CPU temp.  Calculate a new DUTY_CPU.
# Send to function adjust_fans.
##############################################
function CPU_check_adjust() {
    # IPMI methods of checking CPU temp:
    #   CPU_TEMP=$($IPMITOOL sdr | grep "CPU.* Temp" | grep -Eo '[0-9]{2,5}')
    #   CPU_TEMP=$($IPMITOOL sensor get "CPU Temp" | awk '/Sensor Reading/ {print $4}')

    # Only works on FreeBSD
    # Find hottest CPU core
    # echo "Checking core temperatures"
    MAX_CORE_TEMP=0
    SDR_OUTPUT=$($IPMITOOL sdr)
    for CORE in $(seq 0 "$CORES"); do
        CORE_TEMP="$(echo "$SDR_OUTPUT" | grep "CPU${CORE} Temp" | grep -Eo '[0-9]{2,5}')"
        if [[ $CORE_TEMP -gt $MAX_CORE_TEMP ]]; then MAX_CORE_TEMP=$CORE_TEMP; fi
    done
    CPU_TEMP=$MAX_CORE_TEMP

    DUTY_CPU_LAST=$DUTY_CPU

    # This will break if settings have non-integers
    DUTY_CPU="$(((CPU_TEMP - CPU_REF) * CPU_SCALE + DUTY_CPU_MIN))"

    # Don't allow duty cycle outside min-max
    if [[ $DUTY_CPU -gt $DUTY_CPU_MAX ]]; then DUTY_CPU=$DUTY_CPU_MAX; fi
    if [[ $DUTY_CPU -lt $DUTY_CPU_MIN ]]; then DUTY_CPU=$DUTY_CPU_MIN; fi

    # echo "Checking fans"
    adjust_fans $ZONE_CPU $DUTY_CPU "$DUTY_CPU_LAST"

    # echo "Sleeping for $CPU_T"
    if [[ $CPU_T -gt 2 ]]; then
        sleep $CPU_T
    else
        sleep $((CPU_T - 1))
    fi

    if [ $CPU_LOG_YES == 1 ]; then
        print_interim_CPU | tee -a $CPU_LOG >/dev/null
    fi
}

# Compute a new setpoint from ambient temperature
function compute_setpoint_from_ambient() {
    ambient_temp=$1
    original_sp=$2

    if (($(echo "$ambient_temp > 15" | bc -l))) && (($(echo "$ambient_temp < 45" | bc -l))); then
    	echo $(bc <<<"scale=2; ($ambient_temp + $AMBIENT_COEFF) / 1")
    else
	printf "Missing or invalid ambient temp!\n"
	USE_AMBIENT_TEMP=0
	echo $original_sp
    fi
}

##############################################
# function DRIVES_check_adjust
# Print time on new log line.
# Go through each drive, getting and printing
# status and temp.  Calculate max and mean
# temp, then calculate PID and new duty.
# Call adjust_fans.
##############################################
function DRIVES_check_adjust() {
    echo # start new line
    # print time on each line
    TIME=$(date "+%H:%M:%S")
    echo -n "$TIME  "
    Tmax=0
    Tsum=0 # initialize drive temps for new loop through drives
    i=0    # initialize count of spinning drives
    while read -r LINE; do
        get_disk_name
        # echo "Device ID: $DEVID"
        /usr/sbin/smartctl -a -n standby "/dev/$DEVID" >/opt/fanctl/tempfile
        RETURN=$? # have to preserve return value or it changes
        BIT0=$((RETURN & 1))
        BIT1=$((RETURN & 2))
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
            # Taking 10th space-delimited field for WD, Seagate, Toshiba, Hitachi
            TEMP=$(grep "Temperature_Celsius" /opt/fanctl/tempfile | awk '{print $10}')
            ((Tsum += TEMP))
            if [[ $TEMP > $Tmax ]]; then Tmax=$TEMP; fi
            ((i += 1))
        fi
        printf "%s%-2d  " "$STATUS" "$TEMP"
    done <<<"$DEVLIST"

    DUTY_PER_LAST=$DUTY_PER

    # if no disks are spinning
    if [ "$i" -eq 0 ]; then
        Tmean=""
        Tmax=""
        P=""
        D=""
        ERRc=""
        DUTY_PER=$DUTY_PER_MIN
    else
        # summarize, calculate PD and print Tmax and Tmean
        # Need value if all drives had been spun down last time
        if [[ $ERRc == "" ]]; then ERRc=0; fi
	
	# Adjust SP for ambient temperature if using
	if [[ $USE_AMBIENT_TEMP == 1 ]]; then
	    AMBIENT_TEMP=$($TEMPTOOL)
	    adjusted_SP=$(compute_setpoint_from_ambient $AMBIENT_TEMP $SP)
	else
	    adjusted_SP=$SP
	fi

        Tmean=$(bc <<<"scale=2; $Tsum / $i")
        ERRp=$ERRc # save previous error before calculating current
        ERRc=$(bc <<<"scale=2; ($Tmean - $adjusted_SP) / 1")
        P=$(bc <<<"scale=3; ($Kp * $ERRc) / 1")
        D=$(bc <<<"scale=4; $Kd * ($ERRc - $ERRp) / $DRIVE_T")
        PD=$(bc <<<"$P + $D") # add corrections

        # round for printing
        Tmean=$(printf %0.2f "$Tmean")
        P=$(printf %0.2f "$P")
        D=$(printf %0.2f "$D")
        PD=$(printf %0.f "$PD") # must be integer for duty

        ((DUTY_PER = DUTY_PER_LAST + PD))

        # Don't allow duty cycle outside min-max
        if [[ $DUTY_PER -gt $DUTY_PER_MAX ]]; then DUTY_PER=$DUTY_PER_MAX; fi
        if [[ $DUTY_PER -lt $DUTY_PER_MIN ]]; then DUTY_PER=$DUTY_PER_MIN; fi
    fi

    # DIAGNOSTIC variables - uncomment for troubleshooting:
    # printf "\n DUTY_PER=%s, DUTY_PER_LAST=%s, DUTY=%s, Tmean=%s, ERRp=%s \n" "${DUTY_PER:---}" "${DUTY_PER_LAST:---}" "${DUTY:---}" "${Tmean:---}" $ERRp

    # pass to the function adjust_fans
    adjust_fans $ZONE_PER $DUTY_PER "$DUTY_PER_LAST"

    # DIAGNOSTIC variables - uncomment for troubleshooting:
    # printf "\n DUTY_PER=%s, DUTY_PER_LAST=%s, DUTY=%s, Tmean=%s, ERRp=%s \n" "${DUTY_PER:---}" "${DUTY_PER_LAST:---}" "${DUTY:---}" "${Tmean:---}" $ERRp

    # print current Tmax, Tmean
    printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"

    if [[ $USE_AMBIENT_TEMP -eq 1 ]]; then
	# print ambient and computed temp
        printf "🌡️%5s %-3s" "${AMBIENT_TEMP:---}" "${adjusted_SP:----}"
    fi
}

##############################################
# function adjust_fans
# Zone, new duty, and last duty are passed as parameters
##############################################
function adjust_fans() {
    # parameters passed to this function
    ZONE=$1
    DUTY=$2
    DUTY_LAST=$3

    # Change if different from last duty, update last duty.
    if [[ $DUTY -ne $DUTY_LAST ]] || [[ FIRST_TIME -eq 1 ]]; then
        # Set new duty cycle. "echo -n ``" prevents newline generated in log
        # Hint: IPMI needs 0-255, not 0-100
        SPEED=$(echo "scale=0; ($DUTY * 255) / 100" | bc)
        echo -n "$($IPMITOOL raw 0x30 0x91 0x5A 0x3 0x1"$ZONE" "$SPEED")"
    fi
}

##############################################
# function print_interim_CPU
# Sent to a separate file by the call
# in CPU_check_adjust{}
##############################################
function print_interim_CPU() {
    RPM=$($IPMITOOL sdr | grep "$RPM_CPU" | grep -Eo '[0-9]{2,5}')
    # print time on each line
    TIME=$(date "+%H:%M:%S")
    echo -n "$TIME  "
    printf "%7s %5d %5d \n" "${RPM:----}" "$CPU_TEMP" "$DUTY"
}

#####################################################
# SETUP
# All this happens only at the beginning
# Initializing values, list of drives, print header
#####################################################
# Print settings at beginning of log
printf "\n****** SETTINGS ******\n"
printf "CPU zone %s; Peripheral zone %s\n" $ZONE_CPU $ZONE_PER
printf "CPU fans min/max duty cycle: %s/%s\n" $DUTY_CPU_MIN $DUTY_CPU_MAX
printf "PER fans min/max duty cycle: %s/%s\n" $DUTY_PER_MIN $DUTY_PER_MAX
printf "CPU fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" $RPM_CPU_30 $RPM_CPU_MAX
printf "PER fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" $RPM_PER_30 $RPM_PER_MAX
printf "Drive temperature setpoint (C): %s\n" $SP
printf "Kp=%s, Kd=%s\n" $Kp $Kd
printf "Drive check interval (main cycle; minutes): %s\n" $DRIVE_T
printf "CPU check interval (seconds): %s\n" $CPU_T
printf "CPU reference temperature (C): %s\n" $CPU_REF
printf "CPU scalar: %s\n" $CPU_SCALE
printf "Logging to: %s\n" $LOG

if [[ CPU_LOG_YES -eq 1 ]]; then
    printf "Logging CPU to: %s\n" $CPU_LOG
else
    printf "Not logging CPU entries\n"
fi

if [[ USE_AMBIENT_TEMP -eq 1 ]]; then
    printf "Using ambient temperature from sensor\n"
    printf "Temperature tool: $TEMPTOOL\n"
    # failsafe if the temperature tool is not valid
    AMBIENT_TEMP=$($TEMPTOOL)
    if (($(echo "$AMBIENT_TEMP > 15" | bc -l))) && (($(echo "$AMBIENT_TEMP < 45" | bc -l))); then
        printf "Raw ambient temperature: $AMBIENT_TEMP°C\n"
        printf "Ambient drive temp adjustment: $AMBIENT_COEFF°C\n"
    else
	printf "Missing temp or temp out of bounds, reverting to standard behavior\n"
	USE_AMBIENT_TEMP=0
    fi
else
    printf "Not using ambient temperature\n"
fi

# Get number of CPU cores to check for temperature
# -1 because numbering starts at 0
CORES=$(($(nproc) - 1))

CPU_LOOPS=$(bc <<<"$DRIVE_T * 45 / $CPU_T") # Number of whole CPU loops per drive loop
ERRc=0                                      # Initialize errors to 0
FIRST_TIME=1

# Alter RPM thresholds to allow some slop
RPM_CPU_LOW=$RPM_CPU_30
RPM_CPU_30=$(echo "scale=0; 1.2 * $RPM_CPU_30 / 1" | bc)
RPM_CPU_MAX=$(echo "scale=0; 0.8 * $RPM_CPU_MAX / 1" | bc)
RPM_PER_LOW=$RPM_PER_LOW
RPM_PER_30=$(echo "scale=0; 1.2 * $RPM_PER_30 / 1" | bc)
RPM_PER_MAX=$(echo "scale=0; 0.8 * $RPM_PER_MAX / 1" | bc)

# Get list of drives
DEVLIST1=$(lsblk -rnS | grep ATA)
# Remove lines with flash drives, SSDs, other non-spinning devices; edit as needed (added HGST)
DEVLIST="$(echo "$DEVLIST1" | sed '/HGST/d;/KINGSTON/d;/ADATA/d;/SanDisk/d;/OCZ/d;/LSI/d;/INTEL/d;/TDKMedia/d;/SSD/d')"
DEVCOUNT=$(echo "$DEVLIST" | wc -l)

# These variables hold the name of the other variables, whose
# value will be obtained by indirect reference
if [[ ZONE_PER -eq 0 ]]; then
    RPM_PER=FAN1
    RPM_CPU=FANA
else
    RPM_PER=FANA
    RPM_CPU=FAN1
fi

read_fan_data

# If mode not Full, set it to avoid BMC changing duty cycle
# Need to wait a tick or it may not get next command
# "echo -n" to avoid annoying newline generated in log
if [[ MODE -ne 1 ]]; then
    echo -n "$($IPMITOOL raw 0x30 0x45 1 1)"
    sleep 1
fi

# Need to start drive duty at a reasonable value if fans are
# going fast or we didn't read DUTY_* in read_fan_data
# (second test is TRUE if DUTY_* is unset).
if [[ ${!RPM_PER} -ge RPM_PER_MAX || -z ${DUTY_PER+x} ]]; then
    echo -n "$($IPMITOOL raw 0x30 0x91 0x5A 0x3 0x1$ZONE_PER 127)"
    DUTY_PER=50
fi
if [[ ${!RPM_CPU} -ge RPM_CPU_MAX || -z ${DUTY_CPU+x} ]]; then
    echo -n "$($IPMITOOL raw 0x30 0x91 0x5A 0x3 0x1$ZONE_CPU 127)"
    DUTY_CPU=50
fi

# Before starting, go through the drives to report if
# smartctl return value indicates a problem (>2).
# Use -a so that all return values are available.
while read -r LINE; do
    get_disk_name
    /usr/sbin/smartctl -a -n standby "/dev/$DEVID" >/opt/fanctl/tempfile
    if [ $? -gt 2 ]; then
        printf "\n"
        printf "*******************************************************\n"
        printf "* WARNING - Drive %-4s has a record of past errors,   *\n" "$DEVID"
        printf "* is currently failing, or is not communicating well. *\n"
        printf "* Use smartctl to examine the condition of this drive *\n"
        printf "* and conduct tests. Status symbol for the drive may  *\n"
        printf "* be incorrect (but probably not).                    *\n"
        printf "*******************************************************\n"
    fi
done <<<"$DEVLIST"

printf "\n%s %36s %s \n" "Key to drive status symbols:  * spinning;  _ standby;  ? unknown" "Version" $VERSION
print_header

# for first round of printing
CPU_TEMP=$(echo "$SDR" | grep "CPU2 Temp" | grep -Eo '[0-9]{2,5}')

# Initialize CPU log
if [ $CPU_LOG_YES == 1 ]; then
    printf "%s \n%s \n%17s %5s %5s \n" "$DATE" "Printed every CPU cycle" $RPM_CPU "Temp" "Duty" | tee $CPU_LOG >/dev/null
fi

###########################################
# Main loop through drives every DRIVE_T minutes
# and CPU every CPU_T seconds
###########################################
while true; do
    # Print header every quarter day.  awk removes any
    # leading 0 so it is not seen as octal
    HM=$(date +%k%M)
    HM=$(echo "$HM" | awk '{print $1 + 0}')
    R=$((HM % 600)) # remainder after dividing by 6 hours
    if ((R < DRIVE_T)); then
        print_header
    fi

    DRIVES_check_adjust
    sleep 3 # Let fans equilibrate to duty before reading fans and testing for reset
    read_fan_data
    FIRST_TIME=0

    printf "%7s %6s %6.6s %4s %-7s %3d %3d %6s %5s %5s %5s %5s" "${ERRc:----}" "${P:----}" "${D:----}" "$CPU_TEMP" $MODEt $DUTY_CPU $DUTY_PER "${FANA:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}"

    # See if BMC reset is needed
    # ${!RPM_CPU} gets updated value of the variable RPM_CPU points to
    # Took following conditions out (fans too fast) to avoid serial resets
    #	|| (DUTY_CPU -le 30 && ${!RPM_CPU} -gt RPM_CPU_30)
    #	|| (DUTY_PER -le 30 && ${!RPM_PER} -gt RPM_PER_30)

    if [[ (DUTY_CPU -ge 95 && ${!RPM_CPU} -lt RPM_CPU_MAX) ]]; then
        RESET=1
        MSG=$(printf "\n%s\n" "BMC reset: RPMs were too low for DUTY_CPU -- DUTY_CPU=$DUTY_CPU; RPM_CPU=${!RPM_CPU}")
    fi
    if [[ (DUTY_PER -ge 95 && ${!RPM_PER} -lt RPM_PER_MAX) ]]; then
        RESET=1
        MSG=$(printf "\n%s\n" "BMC reset: RPMs were too low for DUTY_PER -- DUTY_PER=$DUTY_PER; RPM_PER=${!RPM_PER}")
    fi
    if [[ (${!RPM_PER} -lt RPM_PER_LOW) || (${!RPM_CPU} -lt RPM_CPU_LOW) ]]; then
        RESET=1
        MSG=$(printf "\n%s\n" "BMC reset: RPMs below minimum threshold")
    fi
    if [[ "$RESET" -eq 1 ]]; then
        $IPMITOOL bmc reset cold
        echo "$MSG"
        sleep 120 # mine takes 105 seconds to reset
        RESET=0
    fi

    # CPU loop
    i=0
    while [ $i -lt "$CPU_LOOPS" ]; do
        # echo "CPU Loop: $(($i + 1)) / $CPU_LOOPS"
        CPU_check_adjust
        ((i += 1))
    done
    # echo "Done with loop"
done

# For SuperMicro motherboards with dual fan zones.
# Adjusts fans based on drive and CPU temperatures.
# Includes disks on motherboard and on HBA.
# Mean drive temp is maintained at a setpoint using a PID algorithm.
# CPU temp need not and cannot be maintained at a setpoint,
# so PID is not used; instead fan duty cycle is simply
# increased with temp using reference and scale settings.

# Drives are checked and fans adjusted on a set interval, such as 5 minutes.
# Logging is done at that point.  CPU temps can spike much faster,
# so are checked and logged at a shorter interval, such as 1-15 seconds.
# CPUs with high TDP probably require short intervals.

# Logs:
#   - Disk status (* spinning or _ standby)
#   - Disk temperature (Celsius) if spinning
#   - Max and mean disk temperature
#   - Temperature error and PID variables
#   - CPU temperature
#   - RPM for FANA and FAN1-4 before new duty cycles
#   - Fan mode
#   - New fan duty cycle in each zone
#   - In CPU log:
#        - RPM of the first fan in CPU zone (FANA or FAN1
#        - CPU temperature
#        - new CPU duty cycle

#  Relation between percent duty cycle, hex value of that number,
#  and RPMs for my fans.  RPM will vary among fans, is not
#  precisely related to duty cycle, and does not matter to the script.
#  It is merely reported.
#
#  Percent      Hex         RPM
#  10         A     300
#  20        14     400
#  30        1E     500
#  40        28     600/700
#  50        32     800
#  60        3C     900
#  70        46     1000/1100
#  80        50     1100/1200
#  90        5A     1200/1300
# 100        64     1300

# Duty cycle isn't provided reliably by all boards.  Therefore, by
# default we don't try to read them, and the script just assumes
# that they are what the script last set.  If you want to try reading them,
# go to the function read_fan_data and uncomment the first 4 lines,
# where it reads/converts duty cycles.

################
# Tuning Advice
################
# PID tuning advice on the internet generally does not work well in this application.
# First run the script spincheck.sh and get familiar with your temperature and fan variations without any intervention.
# Choose a setpoint that is an actual observed Tmean, given the number of drives you have.  It should be the Tmean associated with the Tmax that you want.
# Start with Kp low.  Find the lowest ERRc (which is Tmean - setpoint) in the output other than 0 (don't worry about sign +/-).  Set Kp to 0.5 / ERRc, rounded up to an integer.  My lowest ERRc is 0.14.  0.5 / 0.14 is 3.6, and I find Kp = 4 is adequate.  Higher Kp will give a more aggressive response to error, but the downside may be overshooting the setpoint and oscillation.  Kd offsets that, but raising them both makes things unstable and harder to tune.
# Set Kd at about Kp*10
# Get Tmean within ~0.3 degree of SP before starting script.
# Start script and run for a few hours or so.  If Tmean oscillates (best to graph it), you probably need to reduce Kd.  If no oscillation but response is too slow, raise Kd.
# Stop script and get Tmean at least 1 C off SP.  Restart.  If there is overshoot and it goes through some cycles, you may need to reduce Kd.
# If you have problems, examine P and D in the log and see which is messing you up.

# Uses joeschmuck's smartctl method for drive status (returns 0 if spinning, 2 in standby)
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
# Other method (camcontrol cmd -a) doesn't work with HBA
