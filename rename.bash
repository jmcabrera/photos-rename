#!/bin/bash

NOW=$(date +"%Y%m%d_%H%M%S")
# BASE=/share/Uploads/exp/$NOW
# ARCH=$BASE/chronos
unset DRY
unset UNATTENTED
# DST="/share/Photos/chronologique"

function show_help {
	printf \
"
$0 [options] [to_sort]
	-h shows this help
	-d dry run (nothing is actually done)
	-b the base directory, where to link files that have been sorted
	-a the archive directory, where to store the photos by date
	-y everything is accepted

The current directory is recursively searched for files to sort. Files will disapear from here.
They will be moved or hardlinked to the archive (and some of the folders in base for auditing purpose).
"
}

function debug {
# printf \
# "
#   Debug     : in '$1', '$opt', '$OPTIND', '$OPTARG'
#   Analysing       :'$PWD'
#   Moving to (ARCH):'$ARCH'
#   Base      (BASE):'$BASE'
#   Dry-run    (DRY):'${DRY:-unset so no}'
#   Unattended      :'${UNATTENDED:-unset so no}'
# "
return
}

OPTIND=1         # Reset in case getopts has been used previously in the shell.
while getopts "h?dyb:a:" opt
do
    case "$opt" in
    h)
		debug "HELP"
        show_help
        exit 0
        ;;
    d)  DRY="yes"
		debug "DRY"
        ;;
    b)  BASE="$OPTARG"
		debug "BASE"
        ;;
	a)	ARCH="$OPTARG"
		debug "ARCH"
		;;
    y)  UNATTENDED="yes"
		debug "UNAT"
        ;;
    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

BASE=${BASE:-~/.photorg}/$NOW
ARCH=${ARCH:-$BASE/chronos}
CRWL=${1:-$PWD}

printf \
"
I will analyse photos and videos in '${CRWL}'
Organize them in '${ARCH}'
And report in file '${BASE}'
"
[ -z "$DRY" ] || \
  printf "
>>> DRY RUN <<<
I will only report to '${BASE}' what would have been the outcome
but I will not move anything at all.
"

function mymv {
	[ -n "$DRY" ] \
		&& echo "would.mv $@" \
		|| mv $@
}

##############################################################
#ARCH=/share/Photos/chronologique
#ARCH=$BASE/chronos

DONE=$BASE/done
DEL=$BASE/safe_to_delete
AMB=$BASE/ambiguous
ERR=$BASE/errors

mkdir -p $ARCH $DONE $DEL $AMB $ERR

if [ -d $ARCH ] && [ -d $DONE ] && [ -d $DEL ] && [ -d $AMB ] && [ -d $ERR ]
then
	echo created needed directories in $(readlink -f $BASE)
else
	echo cannot create needed directories in $(readlink -f $BASE)
	exit 1
fi


(cat <<END_HELP
Le contenu de ce message est aussi disponible dans le fichier$BASE/README.TXT

Dossier $(readlink -f $DONE):
        contient Les images qui ont bien ete classees.
        Chaque image dans ce dossier est un hardlink vers une image du dossier $ARCH
        Peuvent etre supprimees sans pertes, mais sans gain de place.
Dossier $(readlink -f $DEL):
        Les images qui existaient deja a la bonne position et avec le bon contenu.
        On s'assure que le contenu est le bon en hashant les deux fichiers;
        Les hash doivent etre les memes et les noms aussi.
        Peut donc etre supprime sans perte, et on recuperera de la place.
Dossier $(readlink -f $AMB):
        Les images dans ce dossier auraient ecrase un fichier existant,
        mais dont le contenu n'est pas le meme (pas le meme hash).
        Chaque image dans ce dossier possede une image du meme nom, mais suffixee ORIG
        qui est un hardlink vers le fichier qui aurait ete supprime
        Il ne faut donc **PAS SUPPRIMER CE DOSSIER** avant d'avoir regle tous les conflits.
Dossier $(readlink -f $ERR):
        Les images ou videos dans ce dossier n'ont pas pu etre interpretees.
        il ne faut donc **PAS SUPPRIMER CE DOSSIER** avant d'avoir regle toutes les erreurs.
END_HELP
) > $BASE/README.TXT

printf \
"
  #######################################################
  $(date)
  command line    : $0 ${@@Q}
  Analysing       :'$PWD'
  Moving to (ARCH):'$ARCH'
  Base      (BASE):'$BASE'
  Dry-run    (DRY):'${DRY:-unset so no}'
  Unattended      :'${UNATTENDED:-unset so no}'
  #######################################################
" >> $BASE/debug

function raw_date() {
	local f="$1"
	local ext="$(echo ${f##*.} | tr [:lower:] [:upper:])"

	local retval
	case $ext in

		MPG|MP4|AVI)
			a=$(mediainfo '--Output=General;%Tagged_Date%' "$f" | tr -d '[:alpha:]-:')
			[[ $a =~ .*\ (20[0-9]{6})\ .* ]] && retval=${BASH_REMATCH[1]} || unset retval
			;;

		JPEG|JPG)
			retval=$(exiftool -P -s -DateTimeOriginal -T -d '%Y%m%d' "$f")
			;;
	esac

	if [[ $retval =~ 20[0-9]{6} ]]
	then 
		echo $retval
	fi

}


# Deal with videos
find -type f | while read f
do
	rawdate=$(raw_date "$f")
	prettydate=$(date -d "$rawdate" +"%Y-%m-%d")
	fromdir=$(dirname "$f")
	basext=$(basename "$f")
	base=${basext%.*}
	ext=${basext##*.}
	todir="$ARCH/$prettydate"

echo "rawdate: $rawdate pretty: $prettydate from:$fromdir to:$todir base:$basext" >> $BASE/debug

	if [ -z "$rawdate" ] || [ -z "$prettydate" ]
	then
		## file has no date in its headers. No video or no luck there.
		echo "??? $f"
                mkdir -p "$ERR/$fromdir"
                mv "$f" "$ERR/$fromdir"
	else
		## File has date in its headers
		## Asserting where it should end
		mkdir -p "$todir"
		target="$todir/$basext"
		
		if [ -e "$target" ]
		then
			## Target exists, comparing both
			if [ "$(stat -c '%i' "$target")" == "$(stat -c '%i' "$f")" ]
			then
				# Same inode does not mean same path
				if [ "$(readlink -f "$target")" == "$(readlink -f "$f")" ]
				then
					# file _is_ target, nothing to do.
					echo "=== $f"
				else
					## Both files have the same inode, but different pathes.
					## Moving to "done"
					echo ".== $f"
					mkdir -p "$DONE/$fromdir"
					mv "$f" "$DONE/$fromdir"
				fi
			else
				## Not the same inode, comparing both files' content
				shat=$(sha1sum -b "$target" | cut -f 1 -d' ')
				shaf=$(sha1sum -b "$f" | cut -f 1 -d' ')
				if [ "$shat" == "$shaf" ]
				then
					## Both have the same content: this file goes to "safe_to_delete"
					echo "..= $f"
					mkdir -p "$DEL/$fromdir"
					mv "$f" "$DEL/$fromdir"
				else
					## Both files differ in content. Ouch...
					## Copying the file in 'ambiguous' and linking the file that should have 
					## been overwritten next to it as .ORIG. for further investigation
					echo "/!\ $f"
					mkdir -p "$AMB/$fromdir"
					mv "$f" "$AMB/$fromdir"
					ln "$target" "$AMB/$fromdir/${base}.ORIG.${ext}"
				fi
			fi
		else
			## The target does not exist. Cool !
			## hard linking to the destination and moving to DONE
			echo "--- $f"
			mkdir -p "$DONE/$fromdir"
			ln "$f" "$target"
			mv "$f" "$DONE/$fromdir"
		fi
	fi
done

# Deal with images.
#exiftool -r -P '-Directory<DateTimeOriginal' -d chronos/%Y/%m/%d .

