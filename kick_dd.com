#! /bin/tcsh -f
#
#
#

while ( 1 )
    set pid = `ps -fea | grep -v awk | awk '/dd/ && / obs 8M| obs=8M/{print $2; exit}'`
    if("$pid" != "") kill -USR1 $pid
    sleep 1
end

