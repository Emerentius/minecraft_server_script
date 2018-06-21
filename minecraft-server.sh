#!/bin/bash
# /etc/init.d/minecraft-server
# version 0.9 2014-09-03

### BEGIN INIT INFO
# Provides:   minecraft-server
# Required-Start: $local_fs $remote_fs screen-cleanup
# Required-Stop:  $local_fs $remote_fs
# Should-Start:   $network
# Should-Stop:    $network
# Default-Start:  2 3 4 5
# Default-Stop:   0 1 6
# Short-Description:    Minecraft server
# Description:    Starts the minecraft server
### END INIT INFO

#Settings
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USERNAME="minecraft"
WORLD="GaussRank2"
MC_BASEPATH="/home/minecraft"
MCPATH="${MC_BASEPATH}/${WORLD}"
BACKUPPATH="$MC_BASEPATH/backups/$WORLD"
JARS_FOLDER="$MC_BASEPATH/server_jars"
MOJANG_SERVER_URL="https://s3.amazonaws.com/Minecraft.Download/versions"
which members >/dev/null && SCREEN_USERS=$(members minecraft) #everyone in group minecraft gets screen permissions 
SCREEN_LOG="$MCPATH/screen_temp.log"
SCREEN_NAME="minecraft"
VERSION_FILE="${MCPATH}/version"
VERSIONS_LIST="$JARS_FOLDER/versions.txt"
MAXHEAP=1024
MINHEAP=1024
HISTORY=500
CPU_COUNT=1
OPTIONS="nogui"


ME=`whoami`
as_user() {
  if [ $ME == $USERNAME ] ; then
    bash -c "$1"
  else
    sudo -u $USERNAME bash -c "$1" # USER NEEDS TO HAVE SUDO RIGHTS FOR THIS COMMAND (Passwordless preferably)
	#su - $USERNAME -c "$1"
  fi
}

mc_check_version() {
if [ -f $VERSION_FILE ]; then
	VERSION=$(<$VERSION_FILE) # read version from file "version" in MC folder
	ALL_VERSIONS=$(echo $MCPATH/minecraft_server.*.jar)
	ALL_VERSIONS=${ALL_VERSIONS//"${MCPATH}/minecraft_server."/}	# prefix
	ALL_VERSIONS=${ALL_VERSIONS//".jar"/}							# suffix
	
	for version in $ALL_VERSIONS; do
		pgrep -u $USERNAME -f "minecraft_server.$version.jar" >/dev/null && OLD_VERSION=$version
	done
	
	JAR="minecraft_server.${VERSION}.jar"
	OLD_JAR="minecraft_server.${OLD_VERSION}.jar"
	NO_VERSION=false
	UNCLEAR_VERSION=false
elif [ $(echo $MCPATH/minecraft_server.*.jar | wc -w) == 1 ]; then # only one jar in the server folder exists
	VERSION=$(echo $MCPATH/minecraft_server.*.jar)
	VERSION=${VERSION#"${MCPATH}/minecraft_server."} # prefix
	VERSION=${VERSION%".jar"}				# suffix
	OLD_VERSION=$VERSION
	JAR="minecraft_server.$VERSION.jar"
	OLD_JAR="minecraft_server.${OLD_VERSION}.jar"
	NO_VERSION=true
	UNCLEAR_VERSION=false
else
	NO_VERSION=true
	UNCLEAR_VERSION=true
fi
#complete paths to jars
PATH_NEW_JAR="$JARS_FOLDER/minecraft_server.$VERSION.jar" # If version file exists, this is the path to the jar
PATH_OLD_JAR="$MCPATH/$OLD_JAR"
INVOCATION="java -Xmx${MAXHEAP}M -Xms${MINHEAP}M -XX:+UseConcMarkSweepGC \
-XX:+CMSIncrementalPacing -XX:ParallelGCThreads=$CPU_COUNT -XX:+AggressiveOpts \
-jar $JAR $OPTIONS" 
}

mc_runcheck() {
if sudo -u $USERNAME screen -p 0 -S "$USERNAME/$SCREEN_NAME" -X stuff "" >/dev/null ; then
	return 0
else
	return 1
fi
}

mc_start() {
	if $UNCLEAR_VERSION; then
		echo >&2 "Minecraft version unclear. Set a version via 'set-version <version>' or 'update <version>'."
		exit 1
	fi

	if  mc_runcheck; then
		echo >&2 "$Minecraft $OLD_VERSION is already running!"
	else
		echo "Starting Minecraft $VERSION..."
		cd $MCPATH
		as_user "cd $MCPATH && screen -h $HISTORY -dmS $SCREEN_NAME $INVOCATION"
		as_user "screen -S $SCREEN_NAME -X multiuser on"
		for user in $SCREEN_USERS; do
			as_user "screen -S $SCREEN_NAME -X acladd $user"
		done
		as_user "screen -S $SCREEN_NAME -X logfile \"$SCREEN_LOG\""
		as_user "screen -S $SCREEN_NAME -X logfile flush 0.1"

		sleep 2
		if ! mc_runcheck; then
			echo >&2 "Error! Could not start Minecraft $VERSION!"
			exit 1
		fi

		echo "Minecraft $VERSION is now running."
		JARS_TO_DELETE=$(echo $MCPATH/minecraft_server.*.jar)
		for jar in $JARS_TO_DELETE; do
			if [[ "$jar" != "$MCPATH/minecraft_server.$VERSION.jar" ]]; then
				rm -rf $jar
			fi
		done
	fi
}
 
mc_stop() {
	if mc_runcheck; then
		echo "Stopping Minecraft $OLD_VERSION"
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'say SERVER SHUTTING DOWN IN 10 SECONDS.\n'"
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'save-all\n'"
		sleep 10
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'stop\n'"
		sleep 3
	else
		echo "Minecraft was not running."
		return 0
	fi

	if mc_runcheck; then
		echo >&2 "Error! Minecraft could not be stopped."
		return 1
	else
		echo "Minecraft $OLD_VERSION is stopped."
	fi
}

mc_get_versions() { # downloads a json file indicating all available versions and saves list of versions in file for bash autocompletion
	( # subshell
	cd $JARS_FOLDER
	wget --quiet --timestamping "$MOJANG_SERVER_URL/versions.json"
	CMD="import json; import sys; SRC=open('versions.json'); DATA=json.load(SRC); f=open('versions.txt', 'w');\nfor version in DATA['versions']: print(version['id'], file=f, end=' ')"
	as_user "echo -e \"$CMD\" | python3"
	[ -f $VERSIONS_LIST ] && return 0 || return 1
	)
}

mc_set_version() {
	if [ ! -f $VERSIONS_LIST ]; then
		mc_get_versions || echo >&2 "Couldn't get version list to compare to. Abort setting version." && exit 1
	fi

    VERSIONS="$(<$VERSIONS_LIST)"
	VERSION_IN_LIST=false
	for version in $VERSIONS; do
		[ "$version" = "$1" ] && VERSION_IN_LIST=true
	done

	if $VERSION_IN_LIST; then
		as_user "echo $1 > $VERSION_FILE"
		echo "Set version to $1."
	else
		echo >&2 "No valid version. Use tab-autocompletion for suggestions."
		return 1
	fi
}

mc_update() {
	if [ $# -gt 0 ]; then
		mc_set_version $1 && mc_check_version || return 1
	fi

	if $NO_VERSION; then
		echo >&2 -e "No version set. Use 'update <version>' or 'set-version <version>' to set Minecraft version."	
		return 1
	fi

	if [ ! -f $PATH_NEW_JAR ]; then
		NEW_JAR_URL="$MOJANG_SERVER_URL/$VERSION/minecraft_server.$VERSION.jar"
		echo -e "Downloading jar for version '$VERSION'..."
		(cd $JARS_FOLDER; curl -s -S -fail -O $NEW_JAR_URL) # silent, show errors, fail if no file exists, download from..
	fi

	if [ ! -f $PATH_NEW_JAR ]; then
		echo >&2 "Version '$VERSION' couldn't be downloaded."
		return 1
	fi


    if [ $PATH_OLD_JAR = $PATH_NEW_JAR ]; then
        echo >&2 "You are already running the specified version $VERSION."
    elif [ -f $PATH_NEW_JAR ]; then
		as_user "cp \"$PATH_NEW_JAR\" \"$MCPATH\""
    fi
}

mc_backup() {
	if mc_runcheck; then
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'save-off\n'"
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'save-all\n'"
		sleep 10
		sync
		
		if [[ "$1" = "monthly" ]]; then
			echo "$MCPATH ${BACKUPPATH}_monthly"
			#as_user "rdiff-backup $MCPATH ${BACKUPPATH}_monthly"
		else
			as_user "rdiff-backup $MCPATH $BACKUPPATH"
		fi
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff 'save-on\n'"
	else
		#echo >&2 "Minecraft is not running. Not suspending saves."
		sync
		as_user "rdiff-backup $MCPATH $BACKUPPATH"
	fi
}



mc_command() {
	command="$1";
	if mc_runcheck; then
		as_user "screen -S $SCREEN_NAME -X log on"
		as_user "screen -p 0 -S $SCREEN_NAME -X stuff '$command\n'"
		sleep .11 # assumes that the command will run and print to the log file in less than .1 seconds
		cat "$SCREEN_LOG"
		as_user "screen -S $SCREEN_NAME -X log off"
		rm -rf "$SCREEN_LOG"
	else
		echo >&2 "Minecraft is not running."
		return 1
	fi
}

#Start-Stop here
mc_check_version # update variables
case "$1" in
  start)
    mc_start
    ;;
  stop)
    mc_stop
    ;;
  restart)
    mc_stop && mc_start
    ;;
  update)
	if [ $# -gt 1 ]; then
		[ $# -gt 2 ] && echo >&2 "You need to specify a version." && exit 1
		mc_update $2
	else
		mc_update
	fi
    ;;
  backup)
    mc_backup $2
    ;;
  set-version)
	if [ $# -gt 2 ]; then
		echo >&2 "Only one version can be set."
		exit 1
	elif [ $# -eq 0 ]; then
		echo >&2 "You need to specify a version."
		exit 1
	fi

	mc_set_version $2
    ;;
  get-versions)
	mc_get_versions || echo >&2 "Couldn't get version list." && exit 1
	;;
  status)
    if mc_runcheck && [ "$OLD_VERSION" = "$VERSION" ]; then
		echo "Minecraft $OLD_VERSION is running."
	elif mc_runcheck; then
		echo "Minecraft $OLD_VERSION is running. Version $VERSION will be loaded on restart."
	else
		echo "Minecraft is not running. Version is set to $VERSION"
    fi
    ;;
  command)
    if [ $# -gt 1 ]; then
      shift
      mc_command "$*"
    else
      echo >&2 "Must specify server command (try 'help'?)"
    fi
    ;;
  open-console)
    if ! which members >/dev/null; then
		echo "Missing program: members. Cannot determine user permissions." 
	fi

	if ! mc_runcheck; then
		echo >&2 "Minecraft is not running."
		exit 1
	fi

	ACCESS_PERMISSION=false
	for user in $SCREEN_USERS; do
		echo $ME
		echo $user
		[[ $ME == $user ]] && ACCESS_PERMISSION=true # if user in list, permissions exist
	done

	if $ACCESS_PERMISSION; then
		screen -x "$USERNAME/$SCREEN_NAME"
	else
		echo >&2 "Couldn't open server console. No screen permissions for this user.\nAsk your admin to be added to the group 'minecraft'"
	fi
	;;
  *)
  echo >&2 "Usage: $0 {start|stop|restart|update [<version>]|backup|status|command \"server command\"|open-console}"
  exit 1
  ;;
esac

exit 0
