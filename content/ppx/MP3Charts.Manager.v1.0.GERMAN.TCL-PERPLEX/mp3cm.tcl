#!/bin/tclsh
# CONFIGURATION
set dbfile "mp3cm.dat"
set charts "/cygdrive/e/MP3/CHARTS"
set completeindicator {} ;# reserved option

set charts [file normalize $charts]

package require tdom
load tclsqlite3.dll

sqlite3 db $dbfile
db eval {CREATE TABLE IF NOT EXISTS files (crc32 unsigned int primary key,size unsigned int key,chartid int, name varchar)}
db eval {CREATE TABLE IF NOT EXISTS charts (id INTEGER PRIMARY KEY, path varchar unique, date date, songs smallint)}
db eval {CREATE TABLE IF NOT EXISTS chartfiles (chartid int,rank smallint,crc32 int,size int,primary key (chartid,rank))}
db close

set cmdtable {
	{"create"		create}
	{"buildcinfo"	buildcinfo}
	{"rebuild"		rebuild}
	{"cleanup"		cleanup}
	{"stats"		stats}
}

proc cinfoNewElementCB {dir a b} {
	switch $a {
		"charts" {
			array set charts $b
		}
		"song" {
			array set song $b
			scan $song(crc32) "%x" song(crc32)
			set song(crc32) [format %u $song(crc32)]
			set existingsong [join [sdb eval {SELECT path,name FROM files,charts WHERE crc32=$song(crc32) AND size=$song(size) AND chartid=id}] /]
			puts $dir
			if {[string length $existingsong]!=0} {
				file copy $existingsong $dir/$song(filename)
			}
			return
		}
	}
}

proc cinfoStartXML {wfp} {
	puts $wfp "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>"
	puts $wfp "<!--"
	puts $wfp " generated by mp3crr v1.0"
	puts $wfp " written by poci/PPX"
	puts $wfp "-->"
	puts $wfp "<!DOCTYPE charts \["
	puts $wfp " <!ELEMENT charts (song)+>"
	puts $wfp " <!ATTLIST charts"
	puts $wfp "  date CDATA #REQUIRED"
	puts $wfp "  songs CDATA #REQUIRED"
	puts $wfp "  dirname CDATA #REQUIRED"
	puts $wfp "  version CDATA #REQUIRED"
	puts $wfp " >"
	puts $wfp " <!ELEMENT song EMPTY>"
	puts $wfp " <!ATTLIST song"
	puts $wfp "  rank CDATA #REQUIRED"
	puts $wfp "  size CDATA #REQUIRED"
	puts $wfp "  crc32 CDATA #REQUIRED"
	puts $wfp "  filename CDATA #REQUIRED"
	puts $wfp " >"
	puts $wfp "]>"
}


proc create {argv} {
	global dbfile

	if {[llength $argv]==2} {
		sqlite3 db $dbfile
		foreach {id path} [db eval "SELECT id,path FROM charts"] {
			if {[file tail $path]==[lindex $argv 0]} {break}
		}
		file mkdir [lindex $argv 1]/[file tail $path]
		foreach {rank file dir} [db eval "SELECT rank,name,path FROM charts,files,chartfiles \
		WHERE files.crc32=chartfiles.crc32 AND files.size=chartfiles.size AND chartfiles.chartid=$id AND charts.id=files.chartid"] {
			file copy -force $dir/$file [lindex $argv 1]/[file tail $path]/[format "%03d" $rank][string range $file 3 end]
			puts "$file ($rank)"
		}
		db close
	} elseif {[llength $argv]==1} {
		sqlite3 sdb $dbfile
		expat xmlparser -elementstartcommand [list cinfoNewElementCB [file dirname [join $argv]]]
		if {[catch {xmlparser parsefile [lindex $argv 0]} err]} {
			puts $err
			return
		}
		xmlparser free
		sdb close
	} else {
		puts "create <<charts> <destination dir>>|<chartsinfo.xml file>"
		return
	}
}

proc rebuild {argv} {
	sqlite3 sdb $::dbfile
	foreach {id path} [sdb eval "SELECT id,path FROM charts"] {
		foreach {rank file dir} [sdb eval "SELECT rank,name,path FROM chartfiles a,files b,charts c \
		WHERE a.chartid=$id AND b.chartid!=a.chartid AND a.crc32=b.crc32 AND a.size=b.size AND c.id=b.chartid;"] {
			file delete $path/[format "%03d" $rank][string range $file 3 end]
			file copy -force $dir/$file $path/[format "%03d" $rank][string range $file 3 end]
		}
	}
	sdb close
}

proc cleanup {argv} {
	sqlite3 sdb $::dbfile
	set done 0
	foreach {id path} [sdb eval "SELECT id,path FROM charts"] {
		foreach {rank file dir} [sdb eval "SELECT rank, name, path FROM chartfiles,files, charts WHERE chartfiles.chartid=$id AND files.crc32=chartfiles.crc32 AND files.size=chartfiles.size AND chartfiles.chartid!=files.chartid AND files.chartid=charts.id;"] {
			file delete $path/[format "%03d" $rank][string range $file 3 end]
			file link -hard $path/[format "%03d" $rank][string range $file 3 end] $dir/$file
			incr done
		}
	}
	puts "$done files cleaned up!"
	sdb close
}

proc stats {argv} {
	sqlite3 db $::dbfile
	set total [db eval "SELECT count(*),sum(size)/1024/1024 FROM chartfiles"]
	set cleaned [db eval "SELECT count(*),sum(size)/1024/1024 FROM files"]
	puts "Before cleanup: [format %6u [lindex $total 1]]MB in [format %5u [lindex $total 0]] Files"
	puts "After  cleanup: [format %6u [lindex $cleaned 1]]MB in [format %5u [lindex $cleaned 0]] Files"
	db close
}

proc buildcinfo {argv} {
	if {[llength [split $argv]]!=1} {
		puts "buildcinfo <directory>"
		return
	}
	set directory [file normalize [join $argv]]
	puts $directory
	if {![file isdirectory $directory]} {
		puts "'$directory' is not a directory"
		return
	}
	if {[catch {open $directory/dir.txt} fp]} {
		puts "$fp"
		return
	}
	if {[llength [set sfv [glob -nocomplain "$directory/*.\[sS]\[fF]\[vV]"]]]!=1} {
		puts "none or multiple sfv-files found in '$directory'"
		close $fp
		return
	}
	set sfv [join $sfv]
	if {[catch {open $sfv} sfp]} {
		puts "$sfp"
		close $fp
		return
	}
	if {[catch {open $directory/chartsinfo.xml w} wfp]} {
		puts "$wfp"
		close $fp
		close $sfp
		return
	}
	cinfoStartXML $wfp
	set sfvlines [split [read $sfp] \n]
	set dirlines [split [read $fp] \n]
	set songs 0
	set year "0000"
	set month "00"
	set day "00"
	set dirname [file tail $directory]
	regexp {\w+TOP(\d+)_\w+_(\d\d)_(\d\d)_(\d{4})\w*-MiNiSTRY$} $dirname "" songs day month year
	puts $wfp "<charts version=\"1.0\" date=\"$year-$month-$day\" songs=\"$songs\" dirname=\"$dirname\">"
	foreach dirline $dirlines {
		if {[regexp {.*\s+(\d+)\s+\w\w\w\s+\d+ \d\d+:\d\d (.*\.[mM][pP]3)} $dirline "" size dirfilename]} {
			foreach sfvline $sfvlines {
				if {[regexp {((\d\d\d).+\.[mM][pP]3)\s+([0-9a-fA-F]{8})} $sfvline "" sfvfilename rank crc32]} {
					if {[string equal -nocase $sfvfilename $dirfilename]} {
						puts $wfp " <song rank=\"$rank\" size=\"$size\" crc32=\"[string toupper $crc32]\" filename=\"$dirfilename\" />"
					}
				}
			}
		}
	}
	puts $wfp "</charts>"
	close $wfp
	close $fp
	close $sfp
}

if {[llength [split $argv]]>0} {
	foreach cmd $cmdtable {
		if {[lindex [split $argv] 0]==[lindex $cmd 0]} {
			[lindex $cmd 1] [join [lrange [split $argv] 1 end]]
			return
		}
	}
	puts "unknown subcommand"
	return
}

sqlite3 db $dbfile

foreach chartsdir [glob $charts/*] {
	set aborted 0
	if {[file isdirectory $chartsdir]} {
		if {[regexp {\w+TOP(\d+)_\w+_(\d\d)_(\d\d)_(\d{4})\w*-MiNiSTRY$} $chartsdir "" songs day month year]} {
			set id [db eval "SELECT id FROM charts WHERE path='$chartsdir'"]
			if {$id<=0} {
				switch [llength [set sfv [glob -nocomplain "$chartsdir/*.\[sS]\[fF]\[vV]"]]] {
					0 {
						puts "will not process [file tail $chartsdir] (no sfv found)"
					   	continue
					  }
					1 {
						set otherfiles [glob -nocomplain "$chartsdir/*"]
						if {[llength $otherfiles]==2 && ([string equal -nocase "dir.txt" [file tail [lindex $otherfiles 0]]] || [string equal -nocase "dir.txt" [file tail [lindex $otherfiles 1]]])} {
							buildcinfo $chartsdir
							if {[file exists $chartsdir/chartsinfo.xml]} {
								create $chartsdir/chartsinfo.xml
							}
						}
					}
					default {
						puts "will not process [file tail $chartsdir] ([llength $sfv] sfv-files found)"
						continue
					}
				}
				set files [llength [glob -nocomplain "$chartsdir/*.\[mM]\[pP]3"]]
				if {$files>$songs} {
					puts "will not process [file tail $chartsdir] (too many mp3 files)"
					continue
				} elseif {$files<$songs} {
					puts "will not process [file tail $chartsdir] (too few mp3 files)"
					continue
				}
				set sfv [join $sfv]
				puts -nonewline "scanning [file tail $chartsdir]..."
				flush stdout
				db eval "INSERT INTO charts VALUES (NULL,'$chartsdir','$year-$month-$day',$songs)"
				set cid [db last_insert_rowid]
				set fp [open $sfv]
				set wfp [open $chartsdir/chartsinfo.xml w]
				cinfoStartXML $wfp
				puts $wfp "<charts version=\"1.0\" date=\"$year-$month-$day\" songs=\"$songs\" dirname=\"[file tail $chartsdir]\">"
				set lines [split [read $fp] \n]
				foreach line $lines {
					set song [lindex [split $line] 0]
					if {![regexp "(\[\\d\]{3})\[-().\\w\]*\\.mp3" $song "" rank]} {continue}
					scan [lindex [split $line] 1] "%x" crc
					set crc [format %u $crc]
					if {[file exists $chartsdir/$song]} {
						set size [file size $chartsdir/$song]
						#puts "#$rank $song ($crc)"
						puts $wfp " <song rank=\"$rank\" size=\"$size\" crc32=\"[format %08X $crc]\" filename=\"$song\" />"
						set knownfile [db eval "SELECT path, name FROM files,charts WHERE crc32=$crc AND size=$size AND chartid=id"]
						if {[llength $knownfile]!=2} {
							db eval "INSERT INTO files VALUES ($crc,$size,$cid,'$song')"
						} else {
							# ab hier wird es ernst!! :]
							# update: rausgenommen & cleanup command eingef�hrt
							#file delete -force $chartsdir/$song
							#file link -hard $chartsdir/$song [join $knownfile /]
						}
					} else {
						puts "aborted! (file not found)"
						close $fp
						close $wfp
						set aborted 1
						file delete $chartsdir/chartsinfo.xml
						db eval "DELETE FROM charts WHERE id=$cid"
						db eval "DELETE FROM chartfiles WHERE chartid=$cid"
						db eval "DELETE FROM files WHERE chartid=$cid"
						break
					}
					db eval "INSERT INTO chartfiles VALUES ($cid,$rank,$crc,$size)"
				}
				if {$aborted==1} {
					continue
				}
				puts $wfp "</charts>"
				close $fp
				close $wfp
				puts "done!"
			} else {
				puts "[file tail $chartsdir] skipped! (already scanned)"
			}
		}
	}
}

db close