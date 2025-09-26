#! /bin/tcsh -f
#
#	identify an LTO tape 		-James Holton 7-13-20
#
#

set devtape = /dev/tape

set stream = ""
set tape   = ""
set dir    = ""
set logdir = /data/log/LTO

set BS = 512k
set BS = 8M


foreach arg ( $* )
    set ARG = `echo $arg | awk '{print toupper($1)}'`

    if(-c "$arg") then
	set devtape = "$arg"
	continue
    endif
end


# record the cartridge memory
set cm_name = "831_${stream}_${tape}"
if("$stream" == "alsenable") set cm_name = "${stream}_${tape}"
echo "accessing cartridge memory..."
( sg_raw -o - -r 1024 -t 60 -v $devtape 8c 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 > ! /dev/shm/raw.bin ) >& /dev/null
set noglob
set tape_cm_info = `strings /dev/shm/raw.bin `
set tapeSN = `echo "$tape_cm_info" | awk '{gsub(/[*?]/,"");print $NF}'`
unset noglob
if("$tapeSN" == "") then
    echo "ERROR: no cartridge data"
    set tapeSN = "unknown"
endif
set cmlog_info = `grep "$tapeSN" ${logdir}/cartridge_memory.log | awk '{print $1}'`
if($#cmlog_info != 0) then
    echo "tape previously used as $cmlog_info"
else
    echo "tape not listed in ${logdir}/cartridge_memory.log "
endif

echo "checking tape $devtape ..."
rm -f firstfiles.txt
mt -f $devtape rewind
if($status) then
    set BAD = "no tape! "
    goto exit
endif

foreach BS ( 8M 4M 1M 512k)
    echo "trying BS=$BS"
    set count = `echo $BS 1e9 | awk '$1~/k/{$1*=1000} $1~/M/{$1*=1e6} {print int($2/$1)}'`
    ( setenv TZ UTC ; dd if=$devtape ibs=${BS} count=$count | tar tvf - --utc --full-time >! firstfiles.txt ) >& /dev/null

    set lines = `cat firstfiles.txt | wc -l | awk '{print $1-1}'`
    if($lines >= 2) break
end

if($lines < 2) then
    echo "new tape."
    if($?tarlist) then
        set tape = `echo $tape | awk '{n=length($1);printf "%0"n"d\n", $1+1}'`
    endif
    set fulltape = 0
    goto print_tape
else
    echo "extracting last files"
    mt eod
    mt tell
    set eod = `mt tell | awk '{print $NF}'`
    set seek = `echo $eod $count | awk '{print $1-$2}'`
    mt seek $seek
    mt tell
     ( setenv TZ UTC ; dd if=$devtape ibs=${BS} | tar tivf - --utc --full-time >! lastfiles.txt ) >& /dev/null

endif
set tapesum = `head -$lines firstfiles.txt | md5sum`

set tarlist
foreach tarlist ( `ls -1t /data/log/LTO/backup_LTO_*${stream}*tarlist* /data/log/backup_LTO_*${stream}*tarlist*` )

    set logsum = `head -$lines $tarlist | md5sum`
    if("$logsum" == "$tapesum") break
    set tarlist = ""

end

if("$tarlist" == "") then
    foreach tarlist ( `ls -1t /data/log/LTO/backup_LTO_*tarlist* /data/log/backup_LTO_*tarlist*` )

        set logsum = `head -$lines $tarlist | md5sum`
        if("$logsum" == "$tapesum") break
        set tarlist = ""

    end
endif


if("$tarlist" == "") then
    set BAD = "unknown tape! "
    cat firstfiles.txt
    goto exit
endif

echo "this tape matches: $tarlist"
set fulltape = `tail -n 2 $tarlist | grep -i error | wc -l`

set stream = `echo $tarlist | awk -F "[_]" '{for(i=1;i<=NF;++i) print $i}' | awk '/^LTO/{getline;print}'`
set tape   = `echo $tarlist | awk -F "[_]" '{for(i=1;i<=NF;++i) print $i}' | awk '/^LTO/{++p} p && $1+0>0{print}'`
set dir    = `head -1 firstfiles.txt | awk '{print $6}' | awk -F "[/]" '{print $1"/"}'`
set logdir = `dirname $tarlist`

print_tape:

cat << EOF
set stream = $stream
set tape   = $tape
set dir    = $dir
EOF

if (-e ${logdir}/backup_LTO_${stream}_${tape}.log) then
    set Gbytes = `awk '{sum+=$2} END{print sum/1024^3}' ${logdir}/backup_LTO_${stream}_${tape}.log`
    set files  = `cat ${logdir}/backup_LTO_${stream}_${tape}.log | wc -l`

    echo "tape $stream #$tape contains:"
    echo "$Gbytes GB"
    echo "$files files"
else
    echo "new stream"
endif

if($fulltape) then
    echo "this tape is full. "
else
    echo "tape is not full. "
endif

if($#cmlog_info == 0 && ! $?BAD && $fulltape && "$stream" != "" && "$tape" != "") then
    set cm_name = "831_${stream}_${tape}"
    if("$stream" == "alsenable") set cm_name = "${stream}_${tape}"

    echo "writing $cm_name to tape cartridge memory"
    /usr/src/lto-cm/lto-cm -f $devtape -w "$cm_name"
    sleep 1
    echo "adding $cm_name entry in ${logdir}/cartridge_memory.log"
    sg_raw -o - -r 1024 -t 60 -v $devtape 8c 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 > ! /dev/shm/raw.bin
    set noglob
    set tape_cm_info = `strings /dev/shm/raw.bin `
    echo "tape info: $tape_cm_info"
    echo "${cm_name}   $tape_cm_info" | tee -a ${logdir}/cartridge_memory.log
    unset noglob
endif

exit:
if($?BAD) then
    echo "ERROR: $BAD"
endif

mt -f $devtape eject


if(! -e ${logdir}/backup_LTO_${stream}_${tape}.log) exit

set tapelabel = "8.3.1 $stream"
if("$stream" == "alsenable") set tapelabel = $stream
tape_daterange.com ${logdir}/backup_LTO_${stream}_${tape}.log |\
awk '{print "puts [clock format [clock scan \""$0"\"] -format \"%m %d %y\"]"}' |\
tclsh >! tempfile$$.txt
set tape_daterange = `awk 'NR==2{print $1+0"-"$2+0"-"$3,"to"} NR==5{print $1+0"-"$2+0"-"$3}' tempfile$$.txt`
rm -f tempfile$$.txt
cat << EOF
tape label should read:
$tapelabel #$tape
$tape_daterange
EOF


