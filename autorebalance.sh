#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Usage:
# This script run continuously to attempt to create a balanced node.
# The main idea is to keep minimial liquidity on each channel to at least route some payments.
# The user is expected to customise the script with respect to fees and other parameters. These are
# Available to edit on top of the script.
#
# It can be executed in a TMUX session continuously as
# while true; do . <path_to_script>/autorebalance.sh; done
# Or
# It can be executed as a daily cron job.
#
# BOS (Balance of Satoshi) > 10.20.0 (latest version) needs to be installed
#
# Add the following in crontab to run regulary. Change path as appropriate
# 42 21 * * * <path_to_script>/autorebalance.sh >> ~/autorebalance.log 2>&1
# Version: 0.0.2
# Author:  VS https://t.me/BhaagBoseDk
# 0.0.1 - first version
# 0.0.2 - Added Tip for fun
# 0.0.3 - Handling various bos instllations
# 0.0.4 - Improvement after bos 10.20.0
# 0.1.0 - Reduced Sleep Time, minor varibale name change, other minor updates
# 0.1.1 - Placeholder for customised rebalances; added Out->In rebalcne for heavy local;
#         change to array from local file
#	  use of temporary in memory file system for working directories
# 0.1.2	- use bos call to get MY_KEY
#       - bugfix with temp directory to use PWD if temp area not created.
# 0.1.3 - use special bos tags in peer selection if defined.
# 0.1.4 - allow multiple bos tags
# 0.1.5 - bug fixes in peer selection
#       - only use active nodes
#       - Indicate the executing step number.
# 0.1.6 - Do a nudge to idle peers
#       - bos version 11.10.0
# 0.1.7 - Rebalance CHIVO to remote
#       - bos clean-failed-payments upon exit
# 0.1.8 - Nudge Idle for IN
#       - Use Chivo for Idle in special loop
#       - Send Idle Nudge
# 0.1.9 - Use MINIMUM LIQUIDITY to select suitable peers
#       - code cleanup added functions for each step.
#
script_ver=0.1.9
##       - <to design> use avoid to rebalance key channels
#
# ------------------------------------------------------------------------------------------------
#

min_bos_ver=11.10.0

DEBUG=echo

# define constants
declare -r TRUE=0
declare -r FALSE=1

# Change These Parameters as per your requirements

#If you DO NOT wish to tip 1 sat to author each time you run this script make this value 0. If you wish to increase the tip, change to whatever you want. 
TIP=1

# Max_Fee is kept as high since we will control the rebalance with fee-rate. Change if reuired.
MAX_FEE=50000

#This is the maximum fee used in Step 3 and 4. Keep same if you want
HIGH_MAX_FEE_RATE=1969
HIGH_LIMIT_FEE_RATE=1969

#The normal Rebalance is at  1/3 of High fees
MAX_FEE_RATE=$((HIGH_MAX_FEE_RATE/3))
LIMIT_FEE_RATE=$((HIGH_LIMIT_FEE_RATE/3))

#Loop fees are used for LOOP rebalance
LOOP_MAX_FEE_RATE=2569
LOOP_LIMIT_FEE_RATE=2169

#Consider these channels for decreasing local balance (move to remote) when outbound is above this limit
OUT_OVER_CAPACITY=0.55

# Target rebalance to this capacity of Local. Keep this below 0.5 (50%)
IN_TARGET_OUTBOUND=0.3

# Add in AVOID conditions you want to add to all rebalances
AVOID="--avoid stop"

# Peers to be omitted from outbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered. These are not used in --out
OMIT_OUT=" "

# Peers to be omitted from inbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered. These are not used in --in
OMIT_IN=" "

#Special bos tags
# ab_for_out : peers you prefer to keep local - increaes local if possible. These will not be used as --out
# ab_for_in : peers you prefer to keep remote - increase remote if possible. These will not be use as --in

# Change the tag name here if you have other names for similar purpose you can add multiple with --tag tagname syntax. Make it " " if no tags are required.
TAG_FOR_OUT="--tag ab_for_out"
TAG_FOR_IN="--tag ab_for_in"

#Minimum liquidity required on the direction for rebalance.
MINIMUM_LIQUIDITY=216942

#If you run bos in a specific manner or have alias defined for bos, type the same here and uncomment the line (replace #myBOS= by myBOS= and provide your bos path)
#myBOS="your installation specific way to run bos"

#PubKey for LOOP
LOOP="021c97a90a411ff2b10dc2a8e32de2f29d2fa49d41bfbb52bd416e460db0747d0d"
#PubKey for CHIVO
CHIVO="02f72978d40efeffca537139ad6ac9f09970c000a2dbc0d7aa55a71327c4577a80"

#Idle Days for nudge
IDLE_DAYS=14
NUDGE_AMOUNT=69420
NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

# ------------ START OF SCRIPT ------------
#Set possible BOS paths

if [ -f $HOME/.npm-global/bin/bos ]
then
        BOS="$HOME/.npm-global/bin/bos"
else
        BOS=`which bos`
fi

if [ "$BOS" == "" ] || [ ! -f $BOS ]
then
	if [ "`uname -a | grep umbrel`" != "" ]
        then
		# Potential Docker Installation on umbrel
		BOS="docker run --rm --network=host --add-host=umbrel.local:10.21.21.9 -v $HOME/.bos:/home/node/.bos -v $HOME/umbrel/lnd:/home/node/.lnd:ro alexbosworth/balanceofsatoshis"
	else
		#Other installations
		BOS="docker run --rm --network="generated_default" -v $HOME/.bos:/home/node/.bos alexbosworth/balanceofsatoshis balance"
	fi
fi

if [ "$myBOS" != "" ]
then
	BOS=$myBOS
fi

#BOS=user_specific_path for bos

echo "========= START UP ==========="
echo "==== version $script_ver ===="
date

bos_ver=`$BOS -V`
echo "BOS is $BOS $bos_ver"

if [[ "$bos_ver" < "$min_bos_ver" ]] 
then
 echo "Error -1 : Please upgrade latest bos version equal or higher than $min_bos_ver" 
 exit -1
fi

MY_KEY=`$BOS call getidentity | sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}' | tail -1`

echo "My node pub key ..... $MY_KEY"

#These are temporary directories used by the script
if [  -d /run/user/$(id -u) ]
then
 T_DIR="--tmpdir=/run/user/$(id -u)"
else
 #Use Current Directory as temp area
 T_DIR="--tmpdir=."
fi

MY_T_DIR=$(mktemp -dt "autorebalance.XXXXXXXX" $T_DIR)

echo "Temporary Working Area $MY_T_DIR ... if you terminate the script, do remember to clean manually"

# functions ...............

function init()
{

 date;
 echo "Initialising rebalancing arrays and data ..."

 #Get current peers
 if [ -d ~/utils ]
 then
  cp ~/utils/peers $MY_T_DIR/
 else
  $BOS peers > $MY_T_DIR/peers 2>&1
 fi

 if [ "$TAG_FOR_OUT" != " " ]
 then
  forout_arr=(`$BOS peers --no-color --complete $TAG_FOR_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print "--omit "$2}'`)
  #divide by 2 beause --omit is added
  echo "Found $((${#forout_arr[@]}/2)) special peers to keep local, do not use in --out"

  OMIT_OUT+=${forout_arr[@]}

  # Now get peers for out with available inbound.
  forout_arr=(`$BOS peers --no-color --complete --active --filter "INBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" $TAG_FOR_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "... of which found ${#forout_arr[@]} special peers to keep local with inbound > $MINIMUM_LIQUIDITY, do not use in --out"
 fi

 #$DEBUG $OMIT_OUT

 if [ "$TAG_FOR_IN" != " " ]
 then
  forin_arr=(`$BOS peers --no-color --complete $TAG_FOR_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print "--omit "$2}'`)

  echo "Found $((${#forin_arr[@]}/2)) special peers to keep remote, do not use in --in"

  OMIT_IN+=${forin_arr[@]}

  # Now get peers for in with available outbound.
  forin_arr=(`$BOS peers --no-color --complete --active --filter "OUTBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" $TAG_FOR_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "... of which found ${#forin_arr[@]} special peers to keep remote with outbound > $MINIMUM_LIQUIDITY, do not use in --in"
 fi

 #$DEBUG $OMIT_IN

 if [ $IDLE_DAYS > 0 ]
 then
  #Get idle peers with high outbout to send to remote. Both OMIT_OUT and OMIT_IN is used to prevent duplicates
  idletoin_arr=(`$BOS peers --no-color --complete --active --idle-days $IDLE_DAYS --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_OUT $OMIT_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "Found ${#idletoin_arr[@]} idle peers to shake up to remote, do not use in --in"
  #Add these to OMIT_IN to avoid in --in
  for i in "${idletoin_arr[@]}"
  do
   OMIT_IN+=" --omit $i"
  done

  # The rest of the idle peers would be bought in to local
  idletoout_arr=(`$BOS peers --no-color --complete --active --idle-days $IDLE_DAYS --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_IN $OMIT_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "Found ${#idletoout_arr[@]} idle peers to shake up to local, do not use in --out"
  #Add these to OMIT_OUT to avoid in --out
  for i in "${idletoout_arr[@]}"
  do
   OMIT_OUT+=" --omit  $i"
  done
 fi

 #Get peers with high outbound to send to remote

 sendtoin_arr=(`$BOS peers --no-color --complete --active --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_OUT $OMIT_IN \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#sendtoin_arr[@]} with OUTBOUND > $OUT_OVER_CAPACITY to send to remote, do not use in --in"
 #Add peers which we prefer to send out
 sendtoin_arr+=(${forin_arr[@]})
 sendtoin_arr+=(${idletoin_arr[@]})

 echo "Working with ${#sendtoin_arr[@]} peers to rebalance to remote ... final total, do not use in --in"

 #Get all low outbound channels 80% below minimum to increase local.
 bringtoout_arr=(`$BOS peers --no-color --complete --active --sort outbound_liquidity --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$IN_TARGET_OUTBOUND*8/10" $OMIT_IN $OMIT_OUT \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#bringtoout_arr[@]} with OUTBOUND < $IN_TARGET_OUTBOUND to bring to local, do not use in --out"

 #Add peers which we prefer to bring in
 bringtoout_arr+=(${forout_arr[@]})
 bringtoout_arr+=(${idletoout_arr[@]})

 echo "Working with ${#bringtoout_arr[@]} peers to rebalance to local ... final total, do not use in --out"

 # Save key arrays to file for Debug later
 echo "${forout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/forout
 echo "${forin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/forin
 echo "${idletoin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/idletoin
 echo "${idletoout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/idletoout
 echo "${sendtoin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/sendtoin
 echo "${bringtoout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/bringtoout
 echo "$OMIT_OUT" | sed 's/ 0/\n0/g' > $MY_T_DIR/omitout
 echo "$OMIT_IN" | sed 's/ 0/\n0/g' > $MY_T_DIR/omitin

 if [ ${#sendtoin_arr[@]} -eq 0 ] 
 then
  echo "Error -1 : No outbound peers available for rebalance. Consider lowering OUT_OVER_CAPACITY from "$OUT_OVER_CAPACITY
  return $FALSE
 fi

 if [ ${#bringtoout_arr[@]} -eq 0 ] 
 then
  echo "Error -1 : No inbound peers available for rebalance. Consider lowering IN_TARGET_OUTBOUND from "$IN_TARGET_OUTBOUND
  return $FALSE
 fi
 return $TRUE
}

function send_to_peer()
{
 OUT=$1
 IN=$2
 SEND_AMOUNT=${3:-$NUDGE_AMOUNT}
 MAX_FEE_SEND=${4:-$NUDGE_FEE}
 STEP=${5:-X}
 
 echo -e "\n $STEP... sending $SEND_AMOUNT from $OUT to $IN for max fee $MAX_FEE_SEND"
 echo -e "\n $STEP.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n $STEP.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 echo  -e "\n ... $BOS send $MY_KEY --amount $SEND_AMOUNT --max-fee $MAX_FEE_SEND --out $OUT --in $IN $AVOID && return $TRUE || return $FALSE"

 $BOS send $MY_KEY --amount $SEND_AMOUNT --max-fee $MAX_FEE_SEND --out $OUT --in $IN $AVOID && return $TRUE || return $FALSE
}

function rebalance()
{
 OUT=$1
 IN=$2
 TARGET=$3
 FEE_RATE=${4:-$MAX_FEE_RATE}
 FEE=${5:-$MAX_FEE}

 echo -e "\n ... $BOS rebalance --in $IN --out $OUT $TARGET --avoid FEE_RATE>$LIMIT_FEE_RATE/$IN --avoid $OUT/FEE_RATE>$LIMIT_FEE_RATE --max-fee-rate $FEE_RATE --max-fee $FEE $AVOID && return $TRUE || return $FALSE"

 $BOS rebalance --in $IN --out $OUT $TARGET --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $FEE_RATE --max-fee $FEE $AVOID && return $TRUE || return $FALSE
}

function random_nudge()
{
 #Send message to peer randomly once in 10000 times

 j=$(($RANDOM % 10000));
 #echo $j
 if [ $j = 6942 ]
 then
  echo "... Random nudge $OUT No activity bewteen our channel for 30 days. Please review. Love from $MY_KEY"

  $BOS send $IN --amount 1 --max-fee 1 --message "No activity bewteen our channel for $IDLE_DAYS days. Please review. Love from $MY_KEY"
 fi
}

function idle_to_out()
{
 echo "Step 0 ... Nudging idle peers to CAPACITY/2"
 echo "Working with ${#idletoout_arr[@]} peers to increase outbound balance to CAPACITY/2 via ${#sendtoin_arr[@]} peers to decrease outbound"

 for IN in "${idletoout_arr[@]}"; do \
  j=$(($RANDOM % ${#sendtoin_arr[@]}));
  #Select A random out peer
  OUT=${sendtoin_arr[j]};

  #send a nudge and if success rebalance
  send_to_peer $OUT $IN $NUDGE_AMOUNT $NUDGE_FEE 0 && rebalance $OUT $IN "--in-target-outbound CAPACITY/2"

  date; sleep 1;

  #Send message to peer randomly once in 10000 times
  random_nudge
 done
}

function idle_to_in()
{
 echo "Step 0.5 ... Nudging idle peers to CAPACITY/2"
 echo "Working with ${#idletoin_arr[@]} peers to increase remote balance to CAPACITY/2 via ${#bringtoout_arr[@]} peers to increase outbound"

 for OUT in "${idletoin_arr[@]}"; do \
  j=$(($RANDOM % ${#bringtoout_arr[@]}));
  #Select A random out peer
  IN=${bringtoout_arr[j]};

  #send a nudge and if success rebalance
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+5)) $NUDGE_FEE 0.5 && rebalance $OUT $IN "--out-target-inbound CAPACITY/2"

  date; sleep 1;

  #Send message to peer randomly once in 10000 times
  random_nudge
 done
}


# Rebalance with a random outbound node
function ensure_minimum_local()
{
 echo "Step 1 ... Ensure Local balance if channel local balance is < $IN_TARGET_OUTBOUND"
 echo "Working with ${#bringtoout_arr[@]} peers to increase outbound via ${#sendtoin_arr[@]} peers to decrease outbound"

 for IN in "${bringtoout_arr[@]}"; do \
  j=$(($RANDOM % ${#sendtoin_arr[@]}));
  #Select A random out peer
  OUT=${sendtoin_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+10)) $NUDGE_FEE 1 && rebalance $OUT $IN "--in-target-outbound CAPACITY*$IN_TARGET_OUTBOUND"

  date; sleep 1;
 done
}

function sendtoin_high_local()
{
 echo "Step 2 ... Reducing outbound for channels with outbound  > $OUT_OVER_CAPACITY to CAPACITY/2"
 echo "Working with ${#sendtoin_arr[@]} peers to increase inbound via ${#bringtoout_arr[@]} peers to decrease inbound"

 for OUT in "${sendtoin_arr[@]}"; do \
  j=$(($RANDOM % ${#bringtoout_arr[@]}));
  #Select A random in peer
  IN=${bringtoout_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+20)) $NUDGE_FEE 2 && rebalance $OUT $IN "--out-target-inbound CAPACITY/2"

  date; sleep 1;
 done
}

#The following rebalances are done spefically for ab_for_out and ab_for_in tags. You might want to change the fees if you prefer.
function ab_for_out()
{
 MAX_FEE_RATE=$HIGH_MAX_FEE_RATE
 LIMIT_FEE_RATE=$HIGH_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 echo "Step 3 ... Increasing outbound for channels we prefer to keep local"
 echo "Working with ${#forout_arr[@]} peers to increase outbound via ${#sendtoin_arr[@]} peers to decrease outbound"

 for IN in "${forout_arr[@]}"; do \
  j=$(($RANDOM % ${#sendtoin_arr[@]}));
  #Select A random out peer
  OUT=${sendtoin_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+30)) $NUDGE_FEE 3 && rebalance $OUT $IN "--in-target-outbound CAPACITY"

  date; sleep 1;
 done
}

function ab_for_in()
{
 echo "Step 4 ... Increasing remote for channels we prefer to keep remote"
 echo "Working with ${#forin_arr[@]} peers to increase inbound via ${#bringtoout_arr[@]} peers to decrease inbound"

 for OUT in "${forin_arr[@]}"; do \
  j=$(($RANDOM % ${#bringtoout_arr[@]}));
  #Select A random in peer
  IN=${bringtoout_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+40)) $NUDGE_FEE 4 && rebalance $OUT $IN "--out-target-inbound CAPACITY"

  date; sleep 1;

 done
}

function process_chivo()
{
 echo "Step 4.5 ... Increasing inbound for CHIVO via all peers except sendtoin"
 #Add Idle2In array to bringtoout to improve possibility
 bringtoout_arr+=(${idletoin_arr[@]})

 echo "Working with ${#bringtoout_arr[@]} peers to decrease inbound via $CHIVO to increase inbound"
 #This section is only applicaation if you have channel with Chivo.
 chivo_count=`grep $CHIVO $MY_T_DIR/peers | wc -l`
 if [ $chivo_count -gt 0 ]
 then
  #Try chivo wallet with the idle peer. (improve in future)
  for IN in "${bringtoout_arr[@]}"; do \
   OUT=$CHIVO

   #send a nudge with target rebalance
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+45)) $NUDGE_FEE 4.5 && rebalance $OUT $IN "--out-target-inbound CAPACITY"
   date; sleep 1;
  done
 fi
}

#This section is only applicaation if you have channel with LOOP. Remember to increase fees with LOOP
function process_loop()
{
 loop_count=`grep $LOOP $MY_T_DIR/peers | wc -l` 

 if [ $loop_count -gt 0 ]
 then
  echo "Step 5 ... Reduce Remote for LOOP"
  MAX_FEE_RATE=$LOOP_MAX_FEE_RATE
  LIMIT_FEE_RATE=$LOOP_LIMIT_FEE_RATE

  IN=$LOOP
  echo -e "\n 5.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

  $BOS rebalance --in $IN --in-target-outbound CAPACITY --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;
  date; sleep 1;
 fi
}

function cleanup()
{
 #Cleanup
 echo " ... Cleanup"
 rm -rf $MY_T_DIR
 $BOS clean-failed-payments
}

function tip()
{
 #Tip Author
 if [ $TIP -ne 0 ]
 then
  echo "Thank you... $TIP"
  $BOS send 03c5528c628681aa17ab9e117aa3ee6f06c750dfb17df758ecabcd68f1567ad8c1 --amount $TIP --message "Thank you for rebalancing $MY_KEY"
 fi
}

function final_sleep()
{
 echo "Final Sleep for 3600 seconds you can press ctrl-c"
 date;
 echo "========= SLEEP ========"
 sleep 3600
}

# Start of Script
if init
then
 idle_to_out
 idle_to_in
 ensure_minimum_local
 sendtoin_high_local
 ab_for_out
 ab_for_in
 process_chivo
 process_loop
 tip
else
 echo "... not much to do"
fi
cleanup
final_sleep
