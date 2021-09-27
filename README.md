# autorebalance
	
This script run continuously to attempt to create a balanced node.


Usage:
Most nodes end up suffering from lack of liquidit on their local balace which leads to routing failure on their node as well as loss of reputation and reliability on the network, leading to their node being ignored on paths where there is liquidity.

This script attempts to keep a minimum local balance on most channels to ensure reasonbale routing. Coupled with liquidity driven fee policy (low fee on high local, high fee on low local) it can create a two way routing node and improve the node position within the network.

This script run continuously to attempt to create a balanced node. The main idea is to keep minimial liquidity on each channel to at least route some payments. The user is expected to customise the script with respect to fees and other parameters. These are available to edit on top of the script.  It can be executed in a TMUX session continuously as:


Test it using

<code>
cd <path_to_script>
	
. ./autorebalance.sh 
</code>

Then run continuously if you are comfortable.
	
<code>
	while true; do . <path_to_script>/autorebalance.sh; done
</code>
  
  
Or, it can be executed as a daily cron job. BOS (Balance of Satoshi) needs to be installed Add the following in crontab to run regulary. Change path as appropriate

<code>
	42 21 * * * <path_to_script>/autorebalance.sh >> ~/autorebalance.log 2>&1
</code>

Change TIP=0 if you do not wish to tip the author.

You may have to configure myBOS variable if the script is unable to determine bos installation.
	
Version: 0.0.3

Contact on telegram if there are issues running the script.
	
Author:  VS https://t.me/BhaagBoseDk 
