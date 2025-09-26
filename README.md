
You want to make sure the tape drive is in a system beefy enough to handle the bandwidth.  As long as you have a reasonable number of cheap disks in parallel they don't have any trouble keeping up with the bus. But the bus itself can be limiting (I have found).

This system of scripts  basically uses tar.  Yes, I know its ancient, but that kind of means it will probably also be around for a long time.  Least common denominator.

The main script for writing to tape is this one:
backup_LTO.com

Which needs a few jiffies to be in the $path
msdate.com - prints out the date/time to ms accuracy
linfit.awk - does least-squares fit to two columns of data
tape_daterange.com - estimates the effective date rate of files on a tape
identify_tape.com - figure out which tape is in the drive by scanning log files
and also (not required but nice) is to have this running in the background all the time:
kick_dd.com
this helps in keeping a record of how fast the tape activity is going. If you send the "dd" program a USR1 signal, it spits out a report of the current transfer rates to stderr. The backup_LTO.com program logs stderr. If the tape slows down, then there might be a problem somewhere.

I have a concept in the backup_LTO.com script of a "stream", such as "data" or "home", or "alsenable".  All this really does is control the log file names the script looks to for files that are already backed up.  You also give it a directory on the command line to scan. This is intended to be something like "/data", bu it can be a relative path that is a link to the real thing. Once new files are identified, I use tar to create a very large tarball (no compression) on a disk I call /cache . This is that raid0 array. This file is then written as fast as possible to the tape until it fills up.  Once full, I read back the tape to verify which files are actually on there and readable. I then write this list to a log, which is now one of the lists of files that are already backed-up.  Rinse and repeat.  The lists are both name and date sensitive, so if somebody overwrites a file and gives it a new date stamp, then it is considered "not backed up".

A higher-level script for watching a file system, filling up a raid0 cache drive, and then writing a tape when needed is this:
maintain_tapecache.com
this monitors a file system for new files and rsync-s it to a local /filecache system.  This, in turn, is then fed

Some additional scripts that are useful for de-duplication.
fix_image_dates.com
linkify_image_duplicates.com

All this may be a bit in-grown to my own systems, but I'd like to think the scripts have plenty of configuration options near the top.  If it doesn't work for you, don't waste too much time trying to debug. I'm happy to answer questions.  And yes, I'll throw this into github when I get a chance. Doing a monochromator upgrade today.

