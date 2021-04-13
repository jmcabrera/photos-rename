#!/bin/bash

HERE="$PWD"
NOW=$(date +"%Y%m%d_%H%M%S")
BASE="$HERE/.base/$NOW"

ARCH=$(readlink -f "${1:-$BASE/chrono}")

DONE="$BASE/done.safe_to_delete"
DEL="$BASE/dups.safe_to_delete"
AMB="$BASE/ambiguous.to_inspect"
ERR="$BASE/errors.to_inspect"

mkdir -p "$ARCH" "$DONE" "$DEL" "$AMB" "$ERR"

if [ -d "$ARCH" ] && [ -d "$DONE" ] && [ -d "$DEL" ] && [ -d "$AMB" ] && [ -d "$ERR" ]
then
	echo created needed directories in $(readlink -f "$BASE")
else
	echo cannot create needed directories in $(readlink -f "$BASE")
	exit 1
fi

printf "
Dossier $(readlink -f "$DONE"):
        contient Les images qui ont bien ete classees.
        Chaque image dans ce dossier est un hardlink vers une image du dossier $ARCH
        Peut etre supprimee sans pertes, mais sans grand gain de place.
Dossier $(readlink -f "$DEL"):
        Les images qui existaient deja a la bonne position et avec le bon contenu.
        On s'assure que le contenu est le bon en hashant les deux fichiers;
        Les hash doivent etre les memes et les noms aussi.
        Peut donc etre supprime sans perte, et recuperera de la place.
		(N.B: les metadonnees ne sont pas comparees)
Dossier $(readlink -f "$AMB"):
        Les images dans ce dossier auraient ecrase un fichier existant,
        mais dont le contenu n'est pas le meme (pas le meme hash).
        Chaque image dans ce dossier possede une image du meme nom, mais suffixee ORIG
        qui est un hardlink vers le fichier qui aurait ete ecrase
        Il ne faut donc **PAS SUPPRIMER CE DOSSIER** avant d'avoir regle tous les conflits.
Dossier $(readlink -f "$ERR"):
        Les images ou videos dans ce dossier n'ont pas pu etre interpretees.
        il ne faut donc **PAS SUPPRIMER CE DOSSIER** avant d'avoir regle toutes les erreurs.
" > "$BASE/README.TXT"

date >> "$BASE/debug"

echo "############################################"""
cat "$BASE/README.TXT"
echo "############################################"""
echo "Sorting '$HERE' to '$ARCH'"
read -p "press any key to continue"

function raw_date() {
	local f="$1"
	local ext="$(echo "${f##*.}" | tr [:lower:] [:upper:])"

	local retval
	case $ext in

		MOV|MPG|MP4|AVI)
			a=$(mediainfo '--Output=General;%Tagged_Date%' "$f" | tr -d '[:alpha:]-:')
			[[ $a =~ .*\ (20[0-9]{6})\ .* ]] && retval=${BASH_REMATCH[1]} || unset retval
			;;

		JPEG|JPG)
			retval=$(exiftool -P -s -DateTimeOriginal -T -d '%Y%m%d' "$f" 2> /dev/null)
			[[ "$retval" =~  20[0-9]{6} ]] \
				|| retval=$(exiftool -P -s -ModifyDate -T -d '%Y%m%d' "$f" 2> /dev/null)
	esac

	if [[ $retval =~ 20[0-9]{6} ]]
	then 
		echo $retval
	fi

}

printf "
For each file, we calculate its destination file inside $ARCH.
The following outcomes can arise:

???  No date can be infered from file's metadata
      - The file goes to $ERR

---  The destination does not exist yet.
      - Moving and hardlinking to '$DONE'

===  The file is already where it should be:
      - We do nothing

.==  The destination is already a hardlink to this file,
      - File is moved to '$DONE'

..=  The destination is a different file with the same content.
      - File is a duplicate, moved to '$DEL'

/!\  The destination exists with different contents.
      - File is moved to '$AMB'
      - Destination is hardlinked to '$AMB/file.ORIG.ext'
"  | tee "$BASE/log"

find ! -path "./.base/*" -type f | while read f
do
	rawdate=$(raw_date "$f")
	prettydate=$(date -d "$rawdate" +"%Y-%m-%d")
	fromdir=$(dirname "$f")
	basext=$(basename "$f")
	base="${basext%.*}"
	ext="${basext##*.}"
	todir="$ARCH/$prettydate"

echo "rawdate: $rawdate pretty: $prettydate from:'$fromdir' to:'$todir' base:$basext" >> "$BASE/debug"

	if [ -z "$rawdate" ] || [ -z "$prettydate" ]
	then
		## file has no date in its headers. No media or no luck there.
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
			## Target exists, comparing inode number
			if [ "$(stat -c '%i' "$target")" == "$(stat -c '%i' "$f")" ]
			then
				# Same inode does not mean same path, follow any 
				# symbolic links to the real path
				if [ "$(readlink -f "$target")" == "$(readlink -f "$f")" ]
				then
					# file _is_ target, nothing to do.
					echo "=== '$f' '$prettydate'"
				else
					## Both files have the same inode, but different pathes.
					## Moving to "done"
					echo ".== '$f' '$prettydate'"
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
					echo "..= '$f' '$prettydate'"
					mkdir -p "$DEL/$fromdir"
					mv "$f" "$DEL/$fromdir"
				else
					## Both files differ in content. Ouch...
					## Copying the file in 'ambiguous' and linking the file that should have 
					## been overwritten next to it as .ORIG. for further investigation
					echo "/!\ '$f' '$prettydate'"
					mkdir -p "$AMB/$fromdir"
					mv "$f" "$AMB/$fromdir"
					ln "$target" "$AMB/$fromdir/${base}.ORIG.${ext}"
				fi
			fi
		else
			## The target does not exist. Cool !
			## hard linking to the destination and moving to DONE
			echo "--- '$f' '$prettydate'"
			mkdir -p "$DONE/$fromdir"
			ln "$f" "$target"
			mv "$f" "$DONE/$fromdir"
		fi
	fi
done | tee -a "$BASE/log"

# Deal with images.
#exiftool -r -P '-Directory<DateTimeOriginal' -d chronos/%Y/%m/%d .

