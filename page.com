#! /bin/tcsh -f
#
#	send email to somebody's cell phone
#
#
set path = ( /programs/beamline/ $path )
rehash
# "database" of cell numbers:
set numbers = /data/calibrations/pager_numbers.txt
goto Setup
Help:
cat << EOF
usage: page.com name message
where: name is the person/lab you want to page
       message is the text you want to send them
       
example:

page.com beamline "beam is back up"

EOF
exit 9

Setup:
# backup, in case things change
if(! -e "$numbers") set numbers = ~/pager_numbers.txt
if(! -e "$numbers") then
    set numbers = /tmp/numbers$$
    cat << EOF >! $numbers
5558675309@txt.att.net             ATT Customer
5558675309@vtext.com               Verizon Customer
EOF
endif

# come up with a call-back phone number
set callback = 5108675309
set beamline = `beamline.com`

if("$1" == "") goto Help
set name = "$1"
if ("$name" == "") goto Help
set message = ( $* )
set message[1] = ""
if ("$message" == "") set message = "you have beamtime! "

set now = `date | awk '{print $4}' | awk -F "[:]" '{print $1":"$2}'`
set now = `date +"%l:%M %p"`

# this helps make sure "duplicate" pages get through
set message = "$now $message"

# extract the cell phone's email address from the list
set number = `grep -i "$name" $numbers | head -1 | awk '{print $1}'`
# delete temporary phone number file (if it's there)
if("$numbers" =~ *$$) rm -f $numbers
if("$name" =~ *@*) set number = "$name"
if("$number" == "") goto Help

# do the actual email
echo "sending "\""$message"\"" to $number"
echo "${message}" | mail ${number}

exit

