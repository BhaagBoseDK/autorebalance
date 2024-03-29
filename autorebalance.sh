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
# 0.0.1 - First version
# 0.0.2 - Added Tip for fun
# 0.0.3 - Handling various bos instllations
# 0.0.4 - Improvement after bos 10.20.0
# 0.1.0 - Reduced Sleep Time, minor varibale name change, other minor updates
# 0.1.1 - Placeholder for customised rebalances; added Out->In rebalcne for heavy local;
#       - Change to array from local file
#	- Use of temporary in memory file system for working directories
# 0.1.2	- Use bos call to get MY_KEY
#       - Bugfix with temp directory to use PWD if temp area not created.
# 0.1.3 - Use special bos tags in peer selection if defined.
# 0.1.4 - Allow multiple bos tags
# 0.1.5 - Bug fixes in peer selection
#       - Only use active nodes
#       - Indicate the executing step number.
# 0.1.6 - Do a nudge to idle peers
#       - bos version 11.10.0
# 0.1.7 - Rebalance CHIVO to remote
#       - bos clean-failed-payments upon exit
# 0.1.8 - Nudge Idle for IN
#       - Use Chivo for Idle in special loop
#       - Send Idle Nudge
# 0.1.9 - Use MINIMUM LIQUIDITY to select suitable peers
#       - Code cleanup added functions for each step.
# 0.2.0 - Using unclassified peers in the high value rebalnce.
#       - init after each function
#       - Reorder sequence and other logics
#       - Check depleting peers after successful rebalance
#       - Random Reconnect
# 0.2.1 - Step Text
#       - Favour zerofees for --in peers
#       - Avoid Not required if Global Avoid is defined (bos 11.16.1 onwards)
# 0.2.2 - Fee Variables can be defined in environment now.
#       - Only init when required (after events which change channel capacity)
#       - Only do 25% of peers for Chivo
# 0.2.3 - Place for two way channels
#       - Sniper Mode (keep hitting until capacity reached)
# 0.2.4 - Minimimm Liquidity related minor adjustments.
# 0.2.5 - Randomise Loop Rebalance
#       - Using AVOID for send.
# 0.2.6 - Changes related to leaving Minimum Liquidity on Channels.
#       - make zero fee peers available for out rebalance too.
#       - only rebalance 2w which have routed in last active_days
#       - Append to peers file
#       - Only rebalance if there was a recent forward.
#       - Dynamic Rebalance Fee based on OUT channel.
# 0.2.7 - Minor Changes
#       - IN,OUT_REBAL targets instead of 100%.
# 0.2.8 - Avoid high fee routes
script_ver=0.2.8
##       - <to design> use avoid to rebalance key channels
#
# ------------------------------------------------------------------------------------------------
#

min_bos_ver=11.16.1

DEBUG=:

# define constants
declare -r TRUE=0;
declare -r FALSE=1;
RANDOM=$(date +%s);

# Change These Parameters as per your requirements

#If you DO NOT wish to tip 1 sat to author each time you run this script make this value 0. If you wish to increase the tip, change to whatever you want.
TIP=1

# Max_Fee is kept as high since we will control the rebalance with fee-rate. Change if reuired.
MAX_FEE=500000

#This is the maximum fee used in for targeted rebalances (what earns you most fees).
#Fee variables can be defined in environment so you do not have to change the values after each git pull.
BASE_ROUTING_FEE=369
BASE_FEE=$((BASE_ROUTING_FEE*69/100))

HIGH_MAX_FEE_RATE=${HIGH_MAX_FEE_RATE:-$BASE_FEE}
HIGH_LIMIT_FEE_RATE=${HIGH_LIMIT_FEE_RATE:-$HIGH_MAX_FEE_RATE}

#The normal/opportunistic Rebalance is at 1/5 of High fees
LOW_MAX_FEE_RATE=${LOW_MAX_FEE_RATE:-$((HIGH_MAX_FEE_RATE/5))}
LOW_LIMIT_FEE_RATE=${LOW_LIMIT_FEE_RATE:-$((HIGH_LIMIT_FEE_RATE/5))}

#Loop fees are used for LOOP rebalance
LOOP_MAX_FEE_RATE=${LOOP_MAX_FEE_RATE:-2569}
LOOP_LIMIT_FEE_RATE=${LOOP_LIMIT_FEE_RATE:-$LOOP_MAX_FEE_RATE}

#Consider these channels for decreasing local balance (move to remote) when outbound is above this limit
OUT_OVER_CAPACITY=0.5

# Target rebalance to this capacity of Local. Keep this below 0.5 (50%)
IN_TARGET_OUTBOUND=0.15

# Rebalance Target
TG_OUT_REBAL=0.69
TG_IN_REBAL=0.69

# Target rebalance for 2 way channels
TWO_WAY_TARGET=0.5

# Add in AVOID conditions you want to add to all rebalances
AVOID=" "

# Peers to be omitted from outbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered. These are not used in --out
gOMIT_OUT=" "

# Peers to be omitted from inbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered. These are not used in --in
gOMIT_IN=" "

#Special bos tags
# ab_for_out : peers you prefer to keep local - increaes local if possible. These will not be used as --out
# ab_for_in : peers you prefer to keep remote - increase remote if possible. These will not be use as --in

# Change the tag name here if you have other names for similar purpose you can add multiple with --tag tagname syntax. Make it " " if no tags are required.
TAG_FOR_OUT="--tag ab_for_out --tag fee_a"
TAG_FOR_IN="--tag ab_for_in --tag fee_z"
TAG_FOR_2W="--tag ab_for_2w"

#Minimum liquidity required on the direction for rebalance.
MINIMUM_LIQUIDITY=$((216942*269/100))

#If you run bos in a specific manner or have alias defined for bos, type the same here and uncomment the line (replace #myBOS= by myBOS= and provide your bos path)
#myBOS="your installation specific way to run bos"

#PubKey for LOOP - Must be part of TAG_FOR_OUT
LOOP="021c97a90a411ff2b10dc2a8e32de2f29d2fa49d41bfbb52bd416e460db0747d0d"

#PubKey for CHIVO must be part of TAG_FOR_IN
CHIVO="02f72978d40efeffca537139ad6ac9f09970c000a2dbc0d7aa55a71327c4577a80"

#Idle Days for nudge
IDLE_DAYS=14
ACTIVE_DAYS=30
FEE_DAYS=14
#Assuming good channel would route 5K per day
A_FEE_LIMIT=$((FEE_DAYS*5000))
B_FEE_LIMIT=$((A_FEE_LIMIT/2))
C_FEE_LIMIT=$((B_FEE_LIMIT/2))
D_FEE_LIMIT=$((C_FEE_LIMIT/2))
X_FEE_LIMIT=$((D_FEE_LIMIT/2))
X_FEE=$BASE_FEE
D_FEE=$((BASE_FEE+200))
C_FEE=$((BASE_FEE+400))
B_FEE=$((BASE_FEE+800))
A_FEE=$((BASE_FEE+1600))
NUDGE_AMOUNT=69420
NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

#Sniper Mode will repeat until rebalanced to desired capacity (only applied for high value rebalances)
SNIPER=$TRUE

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
date;
echo "========= START UP ==========="
echo "==== version $script_ver ===="
echo ".. Working with $BASE_ROUTING_FEE base fee rates applying max $LOW_MAX_FEE_RATE:$LOW_LIMIT_FEE_RATE, $HIGH_MAX_FEE_RATE:$HIGH_LIMIT_FEE_RATE, $LOOP_MAX_FEE_RATE:$LOOP_LIMIT_FEE_RATE"
echo ".. Fee limits .."
echo "... A $A_FEE_LIMIT $A_FEE"
echo "... B $B_FEE_LIMIT $B_FEE"
echo "... C $C_FEE_LIMIT $C_FEE"
echo "... D $D_FEE_LIMIT $D_FEE"
echo "... X $X_FEE_LIMIT $X_FEE"

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

init_required=$TRUE

# functions ...............

function init()
{

 if [ $init_required = $TRUE ]
 then
  init_required=$FALSE
 else
  echo ".... init not required, continuing"
  return $TRUE
 fi

 local i;
 date;
 echo "Initialising rebalancing arrays and data ..."

 #Get current peers
 if [ -d ~/utils ]
 then
  tail -2500 ~/utils/peers > $MY_T_DIR/peers
 fi
 $BOS peers --fee-days $FEE_DAYS >> $MY_T_DIR/peers 2>&1

 OMIT_OUT=$gOMIT_OUT
 OMIT_IN=$gOMIT_IN

 if [ "$TAG_FOR_OUT" != " " ]
 then
  forout_arr=(`$BOS peers --no-color --complete $TAG_FOR_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print " --omit "$2}'`)
  #divide by 2 beause --omit is added
  echo "Found $((${#forout_arr[@]}/2)) special peers to keep local, do not use in --out"

  OMIT_OUT+=${forout_arr[@]}

  # Now get peers for out with available inbound.
  forout_arr=(`$BOS peers --no-color --complete --sort outbound_liquidity --active --filter "INBOUND_LIQUIDITY>OUTBOUND_LIQUIDITY*1569/10000" $TAG_FOR_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "... of which found ${#forout_arr[@]} special peers to keep local with inbound > outbound * 15.69%, do not use in --out"
 fi

 #$DEBUG $OMIT_OUT

 if [ "$TAG_FOR_IN" != " " ]
 then
  forin_arr=(`$BOS peers --no-color --complete $TAG_FOR_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print " --omit "$2}'`)

  echo "Found $((${#forin_arr[@]}/2)) special peers to keep remote, do not use in --in"

  OMIT_IN+=${forin_arr[@]}

  # Now get peers for in with available outbound.
  forin_arr=(`$BOS peers --no-color --complete --sort inbound_liquidity --active --filter "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" $TAG_FOR_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "... of which found ${#forin_arr[@]} special peers to keep remote with outbound > inbound * 21.69%, do not use in --in"
 fi
 #$DEBUG $OMIT_IN

 #Two Way channels are to be brought to out (i.e. if they move to remote) and will be used in --in. It is assumed that two way channels move naturally out.
 #A misconfigured 2 way channel can get stuck with all local in which case remove it from 2 way tag.

 if [ "$TAG_FOR_2W" != " " ]
 then
  twoway_arr=(`$BOS peers --no-color --complete $TAG_FOR_2W --sort outbound_liquidity --filter "INBOUND_LIQUIDITY>(INBOUND_LIQUIDITY + OUTBOUND_LIQUIDITY)*$TWO_WAY_TARGET"\
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print " --omit "$2}'`)
  #divide by 2 beause --omit is added
  echo "Found $((${#twoway_arr[@]}/2)) special peers to keep balanced 2-way with inbound > capacity * $TWO_WAY_TARGET, do not use in --out"

  OMIT_OUT+=" "${twoway_arr[@]}

  # Now get fee earnings peers for out with available inbound.
  twoway_arr=(`$BOS peers --fee-days $ACTIVE_DAYS --no-color --complete --sort outbound_liquidity --active --filter "INBOUND_LIQUIDITY>OUTBOUND_LIQUIDITY*10000/2169" $TAG_FOR_2W \
  | grep -v partner_ | grep -e "fee_earnings:" -e "public_key" | grep "fee_earnings:" -A1 | grep public_key: | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "... of which found ${#twoway_arr[@]} 2-way balance special peers active in $ACTIVE_DAYS days to bring to local with inbound > outbound/21.69%"
 fi

 $DEBUG $OMIT_OUT $OMIN_IN
 # Get zero fee peers towards our node based on liquidity divide them in for OUT or IN
 zerofeetoout_arr=(`$BOS peers --no-color --complete --sort outbound_liquidity --active $OMIT_IN --filter "INBOUND_LIQUIDITY>(INBOUND_LIQUIDITY + OUTBOUND_LIQUIDITY)*6942/10000" \
  | grep -e "inbound_fee_rate:" -e "public_key:" | grep -v "partner_public_key:" | grep "([0-9])" -A1  | grep "public_key:" | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#zerofeetoout_arr[@]} zero in fee peers for rebalance to local with inbound > capacity * 69.42%, for use in --in"

 zerofeetoin_arr=(`$BOS peers --no-color --complete --sort inbound_liquidity --active $OMIT_OUT --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY + INBOUND_LIQUIDITY)*6942/10000" \
  | grep -e "inbound_fee_rate:" -e "public_key:" | grep -v "partner_public_key:" | grep "([0-9])" -A1  | grep "public_key:" | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#zerofeetoin_arr[@]} zero in fee peers for rebalance to remote with outbound > capacity * 69.42%, for use in --out"

 # Get peers which are neither in nor out
 therest_arr=(`$BOS peers --no-color --complete --active $OMIT_OUT $OMIT_IN --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(INBOUND_LIQUIDITY + OUTBOUND_LIQUIDITY) * 2169/10000" --filter "INBOUND_LIQUIDITY>(INBOUND_LIQUIDITY + OUTBOUND_LIQUIDITY) * 2169/10000" \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#therest_arr[@]} peers to be use in targetted rebalance with liquidity > 21.69% * capacity on both ends"

 if [ $IDLE_DAYS > 0 ]
 then
  #Get idle peers with high outbout to send to remote. Both OMIT_OUT and OMIT_IN is used to prevent duplicates
  idletoin_arr=(`$BOS peers --no-color --complete --active --idle-days $IDLE_DAYS --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_OUT \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "Found ${#idletoin_arr[@]} idle peers to shake up to remote, do not use in --in"
  #Add these to OMIT_IN to avoid in --in
  for i in "${idletoin_arr[@]}"
  do
   OMIT_IN+=" --omit $i"
  done

  # The rest of the idle peers would be bought in to local
  idletoout_arr=(`$BOS peers --no-color --complete --active --idle-days $IDLE_DAYS --sort outbound_liquidity --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_IN \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

  echo "Found ${#idletoout_arr[@]} idle peers to shake up to local, do not use in --out"
  #Add these to OMIT_OUT to avoid in --out
  for i in "${idletoout_arr[@]}"
  do
   OMIT_OUT+=" --omit  $i"
  done
 fi

 #Get peers with high outbound to send to remote

 local tmp_sendtoin_arr=(`$BOS peers --no-color --complete --active --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_OUT  \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#tmp_sendtoin_arr[@]} with OUTBOUND > $OUT_OVER_CAPACITY to send to remote, do not use in --in"
 #Add peers which we prefer to send out
 unset sendtoin_arr
 sendtoin_arr+=(${forin_arr[@]})
 sendtoin_arr+=(${tmp_sendtoin_arr[@]})
 sendtoin_arr+=(${idletoin_arr[@]})

 echo "Working with ${#sendtoin_arr[@]} peers to rebalance to remote ... final total, do not use in --in"

 #Get all low outbound channels 70% below minimum to increase local.
 local tmp_bringtoout_arr=(`$BOS peers --no-color --complete --active --sort outbound_liquidity --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$IN_TARGET_OUTBOUND*7/10" $OMIT_IN \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 echo "Found ${#tmp_bringtoout_arr[@]} with OUTBOUND < $IN_TARGET_OUTBOUND to bring to local, do not use in --out"

 #Add peers which we prefer to bring in
 unset bringtoout_arr
 bringtoout_arr+=(${forout_arr[@]})
 bringtoout_arr+=(${twoway_arr[@]})
 bringtoout_arr+=(${tmp_bringtoout_arr[@]})
 bringtoout_arr+=(${idletoout_arr[@]})

 echo "Working with ${#bringtoout_arr[@]} peers to rebalance to local ... final total, do not use in --out"

 # Save key arrays to file for Debug later
 echo "${forout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/forout.$step_count
 echo "${forin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/forin.$step_count
 echo "${twoway_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/twoway.$step_count
 echo "${therest_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/therest.$step_count
 echo "${idletoin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/idletoin.$step_count
 echo "${idletoout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/idletoout.$step_count
 echo "${sendtoin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/sendtoin.$step_count
 echo "${bringtoout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/bringtoout.$step_count
 echo "$OMIT_OUT" | sed 's/ 0/\n0/g' > $MY_T_DIR/omitout.$step_count
 echo "$OMIT_IN" | sed 's/ 0/\n0/g' > $MY_T_DIR/omitin.$step_count
 echo "${zerofeetoout_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/zerofeetoout.$step_count
 echo "${zerofeetoin_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/zerofeetoin.$step_count

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

#Function to populate validation file for only fee earning peers to be used in rebalance
function create_fee_db()
{
 date; echo ".. Creating Forward Fee Validation DB for forwards in $FEE_DAYS days";

 $BOS forwards --days $FEE_DAYS --sort earned_total | sed 's/^/ /g' | grep 0 | rev > $MY_T_DIR/fee.db.tmp

 unset AllowForOut_arr; unset AllowForIn_arr; unset AFee_arr; unset BFee_arr; unset CFee_arr; unset DFee_arr; unset XFee_arr;

 while IFS="│" read -r tmp peer liq_out liq_in t_out_fee t_in_fee alias
 do
  group="I"
  fee_group="A"
  peer=`echo $peer | rev`;
  out_fee=`echo $t_out_fee | rev | cut -c 3-10`; out_fee=$((10#$out_fee));
  in_fee=`echo $t_in_fee | rev | cut -c 3-10`; in_fee=$((10#$in_fee));

  [[ $out_fee -lt $in_fee ]] && group="O";
  [[ $out_fee -lt $B_FEE_LIMIT ]] && fee_group="B";
  [[ $out_fee -lt $C_FEE_LIMIT ]] && fee_group="C";
  [[ $out_fee -lt $D_FEE_LIMIT ]] && fee_group="D";
  [[ $out_fee -lt $X_FEE_LIMIT ]] && fee_group="X";

  case $group in
   "O")
    AllowForOut+=($peer)
    ;;
   "I")
    AllowForIn+=($peer)
    ;;
   *)
    echo "...Invalid peer, $group $peer, skipping ..."
    ;;
  esac

  case $fee_group in
   "A")
    AFee_arr+=($peer)
    ;;
   "B")
    BFee_arr+=($peer)
    ;;
   "C")
    CFee_arr+=($peer)
    ;;
   "D")
    DFee_arr+=($peer)
    ;;
   "X")
    XFee_arr+=($peer)
    ;;
   *)
    echo "...Invalid peer, $fee_group $peer, skipping ..."
    ;;
  esac
  printf '%-1s %-1s %-66s %-10s %-10s %-10s %-10s %s\n' $group $fee_group $peer "`echo $liq_out | rev`" "`echo $liq_in | rev`" "`echo $t_out_fee | rev`" "`echo $t_in_fee | rev`" "`echo $alias | rev`" | tee -a $MY_T_DIR/fee.db
 done < $MY_T_DIR/fee.db.tmp

 echo "${AFee_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/AFee_arr.$step_count
 echo "${BFee_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/BFee_arr.$step_count
 echo "${CFee_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/CFee_arr.$step_count
 echo "${DFee_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/DFee_arr.$step_count
 echo "${XFee_arr[@]}" | sed 's/ 0/\n0/g' > $MY_T_DIR/XFee_arr.$step_count

 $DEBUG "AllowForOut " ${AllowForOut[@]}
 $DEBUG "AllowForIn "  ${AllowForIn[@]}
 rm $MY_T_DIR/fee.db.tmp
}

#Check if the peer is allowed for the direction provided
function check_allow_rebalance()
{

 direction=$1
 peer=$2

 date; echo -e "\n ... Validating $peer for $direction ------> \n";  grep $peer $MY_T_DIR/fee.db; grep $peer $MY_T_DIR/peers | tail -1;

 [[ "$direction" == "OUT" && " ${AllowForOut[*]} " =~ " $peer " ]] && return $TRUE || \
 [[ "$direction" == "IN" && " ${AllowForIn[*]} " =~ " $peer " ]] && return $TRUE || \
 {
  # Allow once in a 69
  j=$((RANDOM % 69))
  if [ $j = 0 ]
  then
   echo "... Random Allow"; return $TRUE;
  else
   echo " ... Not Allowed"; return $FALSE;
  fi
 }
}
#Return Max Fees to be used for OUT peer rebalance
function get_fee()
{
 # local -n FEE=$1
 date;
 peer=$1
 grep $peer $MY_T_DIR/fee.db || echo ".... Non Earning Peer, using default fees .. $peer";

 if [[ ${AFee_arr[*]} =~ $peer ]]
 then
  MAX_FEE_RATE=$A_FEE;
 elif [[ ${BFee_arr[*]} =~ $peer ]]
 then
  MAX_FEE_RATE=$B_FEE;
 elif [[ ${CFee_arr[*]} =~ $peer ]]
 then
  MAX_FEE_RATE=$C_FEE;
 elif [[ ${DFee_arr[*]} =~ $peer ]]
 then
  MAX_FEE_RATE=$D_FEE;
 elif [[ ${XFee_arr[*]} =~ $peer ]]
 then
  MAX_FEE_RATE=$X_FEE;
 else
  MAX_FEE_RATE=$((X_FEE*420/1000));
 fi

 $DEBUG "...Calculated Fee $FEE"
}

#Return true if peer capacity matches the filter else false.
function check_peer_capacity()
{
 PEER=$1
 FILTER=$2
 date; echo "... validating $PEER for $FILTER"

 echo -e "\n $BOS peers --no-color --complete --active --filter $FILTER | grep $PEER"

 peer_arr=(`$BOS peers --no-color --complete --active --filter $FILTER | grep $PEER \
  | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

 if [ ${#peer_arr[@]} -gt 0 ]
 then
  echo ".... peer has capacity"
  return $TRUE
 fi
 echo ".... peer is depleted"
 init_required=$TRUE
 return $FALSE
}

function send_to_peer()
{
 OUT=$1
 IN=$2
 SEND_AMOUNT=${3:-$NUDGE_AMOUNT}
 MAX_FEE_SEND=${4:-$NUDGE_FEE}
 STEP=${5:-99}
 STEP_TXT=${6:-X}

 echo -e "\n $STEP:$STEP_TXT... sending $SEND_AMOUNT from $OUT to $IN for max fee $MAX_FEE_SEND"
 echo -e "\n $STEP:$STEP_TXT.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;
 echo -e "\n $STEP:$STEP_TXT.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 if [ $OUT = $IN ]
 then
  #Rare condition, skipp sending
  echo -e "\n ... destination same as source. Skipping"
  return $FALSE
 fi

 date; echo  -e "\n ... $BOS send $MY_KEY --avoid-high-fee-routes --amount $SEND_AMOUNT --avoid FEE_RATE>$LIMIT_FEE_RATE/$IN --avoid $OUT/FEE_RATE>$LIMIT_FEE_RATE --max-fee $MAX_FEE_SEND --out $OUT --in $IN $AVOID && { init_required=$TRUE; return $TRUE; } || return $FALSE"

 $BOS send $MY_KEY --avoid-high-fee-routes --amount $SEND_AMOUNT --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee $MAX_FEE_SEND --out $OUT --in $IN $AVOID && { init_required=$TRUE; return $TRUE; } || return $FALSE
}

function rebalance()
{
 OUT=$1
 IN=$2
 TARGET=$3
 FEE_RATE=${4:-$MAX_FEE_RATE}
 FEE=${5:-$MAX_FEE}

 if [ $OUT = $IN ]
 then
  #Rare condition, skipp sending
  echo -e "\n ... destination same as source. Skipping"
  return $FALSE
 fi

 date; echo -e "\n ... $BOS rebalance --avoid-high-fee-routes --in $IN --out $OUT $TARGET --avoid FEE_RATE>$LIMIT_FEE_RATE/$IN --avoid $OUT/FEE_RATE>$LIMIT_FEE_RATE --max-fee-rate $FEE_RATE --max-fee $FEE $AVOID && { init_required=$TRUE; return $TRUE; } || return $FALSE"

 $BOS rebalance --avoid-high-fee-routes --in $IN --out $OUT $TARGET --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $FEE_RATE --max-fee $FEE $AVOID && { init_required=$TRUE; return $TRUE; } || return $FALSE
}

function random_reconnect()
{
 # Run bos reconnect one out of 5 runs
 j=$((RANDOM % 21))
 if [ $j = 0 ]
 then
  date; echo "... reconnecting inactive peers"
  $BOS reconnect
 fi
}

function random_nudge()
{
 #Send message to peer randomly once in 10000 times

 j=$(($RANDOM % 10000));
 #echo $j
 if [ $j = 6942 ]
 then
  date; echo "... Random nudge $OUT No activity bewteen our channel for 30 days. Please review. Love from $MY_KEY"

  $BOS send $IN --avoid-high-fee-routes --amount 1 --max-fee 1 --message "No activity bewteen our channel for $IDLE_DAYS days. Please review. Love from $MY_KEY"
 fi
}

function idle_to_out()
{
 step=${1:-99}
 step_txt=${2:-X}
 date; echo "Step $step:$step_txt ... Nudging idle peers to CAPACITY/2"
 echo "Working with ${#idletoout_arr[@]} --in peers to increase outbound balance to CAPACITY/2 via ${#sendtoin_arr[@]} --out peers to decrease outbound"

 MAX_FEE_RATE=$LOW_MAX_FEE_RATE
 LIMIT_FEE_RATE=$LOW_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 for IN in "${idletoout_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#idletoout_arr[@]}"

  check_allow_rebalance "IN" $IN || continue;

  j=$(($RANDOM % ${#sendtoin_arr[@]}));
  #Select A random out peer
  OUT=${sendtoin_arr[j]};

  #send a nudge and if success rebalance
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
   { rebalance $OUT $IN "--in-target-outbound CAPACITY/2" &&
     { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
       { echo "... Peer $OUT depleted ... reinitialise ...";
         init || break;
       }
     } || echo "... rebalance failed";
   } || echo "... send failed";

  date; sleep 1;

  #Send message to peer randomly once in 10000 times
  random_nudge
 done
}

function idle_to_in()
{
 step=${1:-99}
 step_txt=${2:-X}
 date; echo "Step $step:$step_txt ... Nudging idle peers to CAPACITY/2"
 echo "Working with ${#idletoin_arr[@]} --out peers to increase remote balance to CAPACITY/2 via ${#bringtoout_arr[@]} --out peers to increase outbound"

 MAX_FEE_RATE=$LOW_MAX_FEE_RATE
 LIMIT_FEE_RATE=$LOW_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 for OUT in "${idletoin_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#idletoin_arr[@]}"

  check_allow_rebalance "OUT" $OUT || continue;

  if [ ${#zerofeetoout_arr[@]} -gt 0 ]
  then
   #prioritise zero fee peers
   j=$(($RANDOM % ${#zerofeetoout_arr[@]}));
   # Prioritise zero fee first
   IN=${zerofeetoout_arr[j]};
   #send a nudge and if success rebalance
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--out-target-inbound CAPACITY/2" &&
      { check_peer_capacity $IN "INBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
        { echo "... Peer $IN depleted ... reinitialise ...";
          init || break;
        }
      } || echo "... rebalance failed";
    } || echo "... send failed";

   date; sleep 1;
  fi
  # them try with other peers
  j=$(($RANDOM % ${#bringtoout_arr[@]}));
  # Select a random peer
  IN=${bringtoout_arr[j]};

  #send a nudge and if success rebalance
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
   { rebalance $OUT $IN "--out-target-inbound CAPACITY/2" &&
     { check_peer_capacity $IN "INBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
       { echo "... Peer $IN depleted ... reinitialise ...";
         init || break;
       }
     } || echo "... rebalance failed";
   } || echo "... send failed";

  date; sleep 1;

  #Send message to peer randomly once in 10000 times
  random_nudge
 done
}

# Rebalance with a random outbound node
function ensure_minimum_local()
{
 step=${1:-99}
 step_txt=${2:-X}
 date; echo "Step $step:$step_txt ... Ensure Local balance if channel local balance is < $IN_TARGET_OUTBOUND"
 echo "Working with ${#bringtoout_arr[@]} --in peers to increase outbound via ${#sendtoin_arr[@]} --out peers to decrease outbound"

 MAX_FEE_RATE=$LOW_MAX_FEE_RATE
 LIMIT_FEE_RATE=$LOW_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 for IN in "${bringtoout_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#bringtoout_arr[@]}"

  check_allow_rebalance "IN" $IN || continue;

  j=$(($RANDOM % ${#sendtoin_arr[@]}));
  #Select A random out peer
  OUT=${sendtoin_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
   { rebalance $OUT $IN "--in-target-outbound CAPACITY*$IN_TARGET_OUTBOUND" &&
     { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
       { echo "... Peer $OUT depleted ... reinitialise ...";
         init || break;
       }
     } || echo "... rebalance failed";
   } || echo "... send failed";

  date; sleep 1;
 done
}

function sendtoin_high_local()
{
 step=${1:-99}
 step_txt=${2:-X}
 date; echo "Step $step:$step_txt ... Reducing outbound for channels with outbound  > $OUT_OVER_CAPACITY to CAPACITY/2"
 echo "Working with ${#sendtoin_arr[@]} --out peers to increase inbound via ${#bringtoout_arr[@]} --in peers to decrease inbound"

 MAX_FEE_RATE=$LOW_MAX_FEE_RATE
 LIMIT_FEE_RATE=$LOW_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 for OUT in "${sendtoin_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#sendtoin_arr[@]}"

  check_allow_rebalance "OUT" $OUT || continue;

  if [ ${#zerofeetoout_arr[@]} -gt 0 ]
  then
   #prioritise zero fee peers
   j=$(($RANDOM % ${#zerofeetoout_arr[@]}));
   # Prioritise zero fee first
   IN=${zerofeetoout_arr[j]};
   #send a nudge and if success rebalance
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--out-target-inbound CAPACITY/2" &&
      { check_peer_capacity $IN "INBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
        { echo "... Peer $IN depleted ... reinitialise ...";
          init || break;
        }
      } || echo "... rebalance failed";
    } || echo "... send failed";

   date; sleep 1;
  fi
  # them try with other peers
  j=$(($RANDOM % ${#bringtoout_arr[@]}));
  #Select A random in peer
  IN=${bringtoout_arr[j]};

  #send a nudge
  send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
   { rebalance $OUT $IN "--out-target-inbound CAPACITY/2" &&
     { check_peer_capacity $IN "INBOUND_LIQUIDITY>$MINIMUM_LIQUIDITY" ||
       { echo "... Peer $IN depleted ... reinitialise ...";
         init || break;
       }
     } || echo "... rebalance failed";
   } || echo "... send failed";

  date; sleep 1;
 done
}

#The following rebalances are done spefically for ab_for_2w tags. You might want to change the fees if you prefer.
function ab_for_2w()
{
 step=${1:-99}
 step_txt=${2:-X}
 #Add the rest array to increase chances.
 local t_sendtoin_arr=(${sendtoin_arr[@]}); t_sendtoin_arr+=(${therest_arr[@]});

 date; echo "Step $step:$step_txt ... Increasing outbound for channels we prefer to keep two way"
 echo "Working with ${#twoway_arr[@]} --in peers to increase outbound for 2 way balance via ${#t_sendtoin_arr[@]} --out peers to decrease outbound"

 MAX_FEE_RATE=$HIGH_MAX_FEE_RATE
 LIMIT_FEE_RATE=$HIGH_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 local send
 for IN in "${twoway_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#twoway_arr[@]}"

  check_allow_rebalance "IN" $IN || continue;

  get_fee $IN
  LIMIT_FEE_RATE=$MAX_FEE_RATE
  NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
  echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"

  while true
  do
   send=$TRUE;
   if [ ${#zerofeetoin_arr[@]} -gt 0 ]
   then
    #prioritise zero fee peers
    j=$(($RANDOM % ${#zerofeetoin_arr[@]}));
    # Prioritise zero fee first
    OUT=${zerofeetoin_arr[j]};
    #send a nudge and if success rebalance
    send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
     { rebalance $OUT $IN "--in-target-outbound CAPACITY*$TWO_WAY_TARGET" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT depleted ... reinitialise ...";
          init || break 2;
        }
      } || { echo "... rebalance failed"; send=$FALSE; }
     } || { echo "... send failed"; send=$FALSE; }

    date; sleep 1;
    if [[ $SNIPER = $TRUE && $send = $TRUE ]]
    then
     date; echo ".... Sniper Activated - retry"; sleep 1;
    else
     break;
    fi
   else
    date; echo ".... No available peers, move on"; break;
   fi
  done

  while true
  do
   send=$TRUE;
   j=$(($RANDOM % ${#t_sendtoin_arr[@]}));
   #Select A random out peer
   OUT=${t_sendtoin_arr[j]};

   #send a nudge
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--in-target-outbound CAPACITY*$TWO_WAY_TARGET" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT depleted ... reinitialise ...";
          init || break 2;
        }
      } || { echo "... rebalance failed"; send=$FALSE; }
    } || { echo "... send failed"; send=$FALSE; }

   date; sleep 1;
   #Exit from While True
   if [[ $SNIPER = $TRUE && $send = $TRUE ]]
   then
    date; echo ".... Sniper Activated - retry"; sleep 1;
   else
    break;
   fi
  done
 done
}

#The following rebalances are done spefically for ab_for_out and ab_for_in tags. You might want to change the fees if you prefer.
function ab_for_out()
{
 step=${1:-99}
 step_txt=${2:-X}
 #Add the rest array to increase chances.
 local t_sendtoin_arr=(${sendtoin_arr[@]}); t_sendtoin_arr+=(${therest_arr[@]});

 date; echo "Step $step:$step_txt ... Increasing outbound for channels we prefer to keep local"
 echo "Working with ${#forout_arr[@]} --in peers to increase outbound via ${#t_sendtoin_arr[@]} --out peers to decrease outbound"

 MAX_FEE_RATE=$HIGH_MAX_FEE_RATE
 LIMIT_FEE_RATE=$HIGH_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 local counter=0
 local send
 for IN in "${forout_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#forout_arr[@]}"
  #While is exit at the end

  check_allow_rebalance "IN" $IN || continue;

  get_fee $IN
  LIMIT_FEE_RATE=$MAX_FEE_RATE
  NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
  echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"

  while true
  do
   send=$TRUE;
   if [ ${#zerofeetoin_arr[@]} -gt 0 ]
   then
    #prioritise zero fee peers
    j=$(($RANDOM % ${#zerofeetoin_arr[@]}));
    # Prioritise zero fee first
    OUT=${zerofeetoin_arr[j]};
    #send a nudge and if success rebalance
    send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
     { rebalance $OUT $IN "--in-target-outbound CAPACITY*$TG_IN_REBAL" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT depleted ... reinitialise ...";
          init || break 2;
        }
      } || echo  "... rebalance failed";
     } || { echo "... send failed"; send=$FALSE; }

    date; sleep 1;
    if [[ $SNIPER = $TRUE && $send = $TRUE ]]
    then
     date; echo ".... Sniper Activated - retry"; sleep 1;
    else
     break;
    fi
   else
    date; echo ".... No available peers, move on"; break;
   fi
  done

  while true
  do
   send=$TRUE;
   j=$(($RANDOM % ${#t_sendtoin_arr[@]}));
   #Select A random out peer
   OUT=${t_sendtoin_arr[j]};

   #send a nudge
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--in-target-outbound CAPACITY*$TG_IN_REBAL" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT depleted ... reinitialise ...";
          init || break 2;
        }
      } || echo "... rebalance failed";
    } || { echo "... send failed"; send=$FALSE; }

   date; sleep 1;
   #Exit from While True
   if [[ $SNIPER = $TRUE && $send = $TRUE  ]]
   then
    date; echo ".... Sniper Activated - retry"; sleep 1;
   else
    break;
   fi
  done
 done
}

function ab_for_in()
{
 step=${1:-99}
 step_txt=${2:-X}
 #Add the rest array to increase chances.
 local t_bringtoout_arr=(${bringtoout_arr[@]}); t_bringtoout_arr+=(${therest_arr[@]});

 date; echo "Step $step:$step_txt ... Increasing remote for channels we prefer to keep remote"
 echo "Working with ${#forin_arr[@]} --out peers to increase inbound via ${#t_bringtoout_arr[@]} --in peers to decrease inbound"

 local counter=0;
 local send;

 for OUT in "${forin_arr[@]}";
 do
  ((counter+=1)); echo ".... peer $counter of ${#forin_arr[@]}"
  #While is exit at the end

  check_allow_rebalance "OUT" $OUT || continue;

  while true
  do
   send=$TRUE;
   if [ ${#zerofeetoout_arr[@]} -gt 0 ]
   then
    #prioritise zero fee peers
    j=$(($RANDOM % ${#zerofeetoout_arr[@]}));
    # Prioritise zero fee first
    IN=${zerofeetoout_arr[j]};

    get_fee $IN
    LIMIT_FEE_RATE=$MAX_FEE_RATE
    NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
    echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"

    #send a nudge and if success rebalance
    send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
     { rebalance $OUT $IN "--out-target-inbound CAPACITY*$TG_OUT_REBAL" &&
      { check_peer_capacity $IN "INBOUND_LIQUIDITY>OUTBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $IN depleted ... reinitialise ...";
          init || break 2;
        }
      } || echo "... rebalance failed";
     } || { echo "... send failed"; send=$FALSE; }

    date; sleep 1;
    if [[ $SNIPER = $TRUE && $send = $TRUE ]]
    then
     date; echo ".... Sniper Activated - retry"; sleep 1;
    else
     break;
    fi
   else
    date; echo ".... No available peers, move on"; break;
   fi
  done

  while true
  do
   send=$TRUE;
   # Now try with other peers.
   j=$(($RANDOM % ${#t_bringtoout_arr[@]}));
   #Select A random in peer
   IN=${t_bringtoout_arr[j]};

   get_fee $IN
   LIMIT_FEE_RATE=$MAX_FEE_RATE
   NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
   echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"

   #send a nudge
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--out-target-inbound CAPACITY*$TG_OUT_REBAL" &&
      { check_peer_capacity $IN "INBOUND_LIQUIDITY>OUTBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $IN depleted ... reinitialise ...";
          init || break 2;
        }
      } || echo "... rebalance failed";
    } || { echo "... send failed"; send=$FALSE; }

   date; sleep 1;
   #Exit from While True
   if [[ $SNIPER = $TRUE && $send = $TRUE ]]
   then
    date; echo ".... Sniper Activated - retry"; sleep 1;
   else
    break;
   fi
  done
 done
}

function process_chivo()
{
 step=${1:-99}
 step_txt=${2:-X}

 date; echo "Step $step:$step_txt ... Increasing inbound for CHIVO"

 MAX_FEE_RATE=$HIGH_MAX_FEE_RATE
 LIMIT_FEE_RATE=$HIGH_LIMIT_FEE_RATE
 NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

 #This section is only applicaation if you have channel with Chivo.
 if [[ ${forin_arr[*]} =~ $CHIVO ]]
 then

  OUT=$CHIVO
  local counter=0

  check_allow_rebalance "OUT" $OUT || return;

  # Prioritise zero fee peers
  for IN in "${zerofeetoout_arr[@]}"
  do
   ((counter+=1)); echo ".... peer $counter of ${#zerofeetoout_arr[@]}"

   get_fee $IN
   LIMIT_FEE_RATE=$MAX_FEE_RATE
   NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
   echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"

   #send a nudge with target rebalance
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--out-target-inbound CAPACITY" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>$INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT completed ... break ...";
          break;
        }
      } || echo "... rebalance failed";
    } || echo "... send failed";

   date; sleep 1;
  done
  #Now try other peers
  #Add the rest array to increase chances.
  local t_bringtoout_arr=(${bringtoout_arr[@]}); t_bringtoout_arr+=(${therest_arr[@]});
  echo "Working with ${#t_bringtoout_arr[@]} --in peers to decrease inbound via --out $CHIVO to increase inbound"

  counter=0
  # Select 25% random peers
  random_peers=($(shuf -i 0-$((${#t_bringtoout_arr[@]}-1)) -n $((${#t_bringtoout_arr[@]}/4))));

  for i in "${random_peers[@]}"
  do
   ((counter+=1)); echo ".... $counter of $((${#t_bringtoout_arr[@]}/4)) random peer $i of ${#t_bringtoout_arr[@]}"
   IN=${t_bringtoout_arr[i]}
   get_fee $IN
   LIMIT_FEE_RATE=$MAX_FEE_RATE
   NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))
   echo "... Fee for rebalance $MAX_FEE_RATE $NUDGE_FEE"
   #send a nudge with target rebalance
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--out-target-inbound CAPACITY" &&
      { check_peer_capacity $OUT "OUTBOUND_LIQUIDITY>INBOUND_LIQUIDITY*2169/10000" ||
        { echo "... Peer $OUT completed ... break ...";
          break;
        }
      } || echo "... rebalance failed";
    } || echo "... send failed";

   date; sleep 1;
  done
 else
  echo "... Chivo $CHIVO not available or have no local balance ... skipping"
 fi
}

#This section is only applicaation if you have channel with LOOP. Remember to increase fees with LOOP
function process_loop()
{
 step=${1:-99}
 step_txt=${2:-X}

 if [[ ${forout_arr[*]} =~ $LOOP ]]
 then

  #Add the rest array to increase chances.
  local t_sendtoin_arr=(${sendtoin_arr[@]}); t_sendtoin_arr+=(${zerrofeetoin_arr[@]}); t_sendtoin_arr+=(${zerofeetoout_arr[@]}); t_sendtoin_arr+=(${therest_arr[@]}); t_sendtoin_arr+=(${twoway_arr[@]}); t_sendtoin_arr+=(${bringtoout_arr[@]});
  date; echo "Step $step:$step_txt ... Reduce Remote for --in LOOP via ${#t_sendtoin_arr[@]} --out peers"

  MAX_FEE_RATE=$LOOP_MAX_FEE_RATE
  LIMIT_FEE_RATE=$LOOP_LIMIT_FEE_RATE
  NUDGE_FEE=$((NUDGE_AMOUNT*MAX_FEE_RATE/1000000))

  local counter=0
  IN=$LOOP

  check_allow_rebalance "IN" $IN || return;

  # Select random peers
  local random_peers=($(shuf -i 0-$((${#t_sendtoin_arr[@]}-1))));

  for i in "${random_peers[@]}"
  do

   ((counter+=1)); echo ".... $counter of ${#t_sendtoin_arr[@]} random peer $i"
   OUT=${t_sendtoin_arr[i]}
   send_to_peer $OUT $IN $((NUDGE_AMOUNT+step)) $NUDGE_FEE $step $step_txt &&
    { rebalance $OUT $IN "--in-target-outbound CAPACITY" &&
      { check_peer_capacity $IN "INBOUND_LIQUIDITY>OUTBOUND_LIQUIDITY*216/10000" ||
        { echo "... Peer $IN completed ... break ...";
          break;
        }
      } || echo "... rebalance failed";
    } || echo "... send failed";

   date; sleep 1;
  done
 else
  echo "... Loop $LOOP not available or have no remote balance ... skipping"
 fi
}

function cleanup()
{
 #Cleanup
 date; echo " ... Cleanup"
 rm -rf $MY_T_DIR
 $BOS clean-failed-payments
}

function tip()
{
 #Tip Author
 if [ $TIP -ne 0 ]
 then
  date; echo "Thank you... $TIP"
  $BOS send 03c5528c628681aa17ab9e117aa3ee6f06c750dfb17df758ecabcd68f1567ad8c1 --amount $TIP --message "Thank you for rebalancing $MY_KEY"
 fi
}

function final_sleep()
{
 sleep_time=69420
 date; echo Final Sleep until `date -d "+$sleep_time seconds"` for $sleep_time seconds you can press ctrl-c
 echo "========= SLEEP ========"
 sleep $sleep_time
}

# Start of Script

#Uncomment on tor nodes
#random_reconnect

create_fee_db;

step_count=0
#For each step, execute init followed by step

#all list
#for run_func in "process_loop" "process_chivo" "ab_for_in" "ab_for_out" "ab_for_2w" "sendtoin_high_local" "ensure_minimum_local" "idle_to_in" "idle_to_out"
for run_func in "process_loop" "ab_for_in" "ab_for_out"
do
 date; echo "Initialising step ... $step_count : $run_func"
 if init
 then
  echo "Starting step ... $step_count:$run_func"
  $DEBUG "$run_func $step_count $run_func"
  $run_func $step_count "$run_func"
 else
  echo "... not much to do"
  break
 fi
 (( step_count+=1 ));
done

tip
cleanup
final_sleep
