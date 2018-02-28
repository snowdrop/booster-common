#!/bin/bash

set -e

RED='\033[0;31m'
NC='\033[0m' # No Color
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'

CURRENT_DIR=`pwd`
CATALOG_FILE=$CURRENT_DIR"/booster-catalog-versions.txt"
rm "$CATALOG_FILE"
touch "$CATALOG_FILE"

declare -a failed=( )


evaluate_mvn_expr() {
    # Evaluate the given maven expression, cf: https://stackoverflow.com/questions/3545292/how-to-get-maven-project-version-to-the-bash-command-line
    result=`mvn -q -Dexec.executable="echo" -Dexec.args='${'${1}'}' --non-recursive exec:exec`
    echo $result
}

log() {
    currentBranch=${branch:-$BRANCH}
    echo -e "\t${GREEN}${currentBranch}${BLUE}: ${1}${NC}"
}

update_parent() {
    # Retrieve current parent version
    PARENT_VERSION=$(evaluate_mvn_expr "project.parent.version")
    parts=( ${PARENT_VERSION//-/ } )
    sb_version=${parts[0]}
    version_int=${parts[1]}
    qualifier=${parts[2]}
    snapshot=${parts[3]}

    # to output parts:
    # echo "${parts[@]}"

    given_version=$1

    # todo: use getopts instead
    # arguments from parent are passed to this script so $2 corresponds to the first param *after* the name of this script
    if [ -n "$given_version" ]; then
        log "Current parent (${YELLOW}${PARENT_VERSION}${BLUE}) will be replaced by version: ${YELLOW}${given_version}"
        NEW_VERSION=${given_version}
    else
        if [[ "$snapshot" == SNAPSHOT ]]
        then
            NEW_VERSION="${sb_version}-$(($version_int +1))-${qualifier}-${snapshot}"
        else
            if [ -n "${qualifier}" ]
            then
                NEW_VERSION="${sb_version}-$(($version_int +1))-${qualifier}"
            else
                NEW_VERSION="${sb_version}-$(($version_int +1))"
            fi
        fi
    fi

    log "Updating parent from ${YELLOW}${PARENT_VERSION}${BLUE} to ${YELLOW}${NEW_VERSION}"

    sed -i '' -e "s/<version>${PARENT_VERSION}</<version>${NEW_VERSION}</g" pom.xml

    # Only attempt committing if we have changes otherwise the script will exit
    if [[ `git status --porcelain` ]]; then

        log "Running verification build"
        if mvn clean verify > build.log; then
            log "Build ${YELLOW}OK"
            rm build.log

            log "Committing and pushing"
            git add pom.xml
            git ci -m "Update to parent ${NEW_VERSION}"
            git push upstream ${BRANCH}
        else
            log "Build ${RED}failed${BLUE}! Check build.log file."
            log "You will need to reset the branch or explicitly set the parent before running this script again."
        fi

    else
        log "Parent was already at ${YELLOW}${NEW_VERSION}${BLUE}. Ignoring."
    fi
}

change_version() {
    if [ -n "$1" ]; then
        newVersion=$1
        if mvn versions:set -DnewVersion=${newVersion} > /dev/null; then
            if [[ `git status --porcelain` ]]; then
                log "Changed version to ${YELLOW}${newVersion}"
                log "Running verification build"
                if mvn clean verify > build.log; then
                    log "Build ${YELLOW}OK"
                    rm build.log

                    log "Committing and pushing"

                    if [ -n "$2" ]; then
                        jira=${2}": "
                    else
                        jira=""
                    fi

                    git ci -am ${jira}"Update version to ${newVersion}"
                    git push upstream ${BRANCH}
                else
                    log "Build ${RED}failed${BLUE}! Check build.log file."
                    log "You will need to reset the branch or explicitly set the parent before running this script again."
                fi

            else
                log "Version was already at ${YELLOW}${newVersion}${BLUE}. Ignoring."
            fi

            find . -name "*.versionsBackup" -delete
        else
            log "${RED}Couldn't set version. Reverting to upstream version."
            git reset --hard upstream/${BRANCH}
        fi
    fi
}

create_branch() {
    branch=$1

    if git ls-remote --heads upstream ${branch} | grep ${branch} > /dev/null;
    then
        log "Branch already exists on remote ${YELLOW}upstream${BLUE}. Ignoring."
    else
        if ! git co -b ${branch} > /dev/null 2> /dev/null;
        then
            log "${RED}Couldn't create branch. Ignoring."
            return 1
        fi
    fi

    unset branch # unset to avoid side-effects in log
}

delete_branch() {
    branch=$1

    if git ls-remote --heads upstream ${branch} | grep ${branch} > /dev/null;
    then
        log "Are you sure you want to delete ${YELLOW}${branch}${BLUE} branch on remote ${YELLOW}upstream${BLUE}?"
        log "Press any key to continue or ctrl-c to abort."
        read foo

        git push -d upstream ${branch}
    else
        log "Branch doesn't exist on remote. ${RED}Ignoring."
    fi

    if ! git branch -D ${branch} > /dev/null 2> /dev/null;
    then
        log "Branch doesn't exist locally. ${RED}Ignoring."
    fi

    unset branch # unset to avoid side-effects in log
}

for BOOSTER in `ls -d spring-boot-*-booster`
do
    #if [ "$BOOSTER" != spring-boot-circuit-breaker-booster ] && [ "$BOOSTER" != spring-boot-configmap-booster ] && [ "$BOOSTER" != spring-boot-crud-booster ]
    if true; then
        pushd ${BOOSTER} > /dev/null

        echo -e "${BLUE}> ${YELLOW}${BOOSTER}${BLUE}${NC}"

        for BRANCH in "master" "redhat"
        do
            # check if branch exists, otherwise skip booster
            if ! git show-ref --verify --quiet refs/heads/${BRANCH}; then
                log "${RED}Branch doesn't exist. Skipping."
                continue
            fi

            # if booster has uncommitted changes, skip it
            if [[ `git status --porcelain` ]]; then
                log "You have uncommitted changes, please stash these changes. ${RED}Ignoring."
                continue
            fi

            # assumes "official" remote is named 'upstream'
            git fetch -q upstream > /dev/null

            git co -q ${BRANCH} > /dev/null && git rebase upstream/${BRANCH} > /dev/null

            # if we need to replace a multi-line match in the pom file of each booster, for example:
            # perl -pi -e 'undef $/; s/<properties>\s*<\/properties>/replacement/' pom.xml

            # if we need to execute sed on the result of find:
            # find . -name "application.yaml" -exec sed -i '' -e "s/provider: fabric8/provider: snowdrop/g" {} +

            if [ -e "$1" ]; then
                script=$1
                log "Running ${YELLOW}${script}${BLUE} script"
                if ! source $1; then
                    log "${RED}Error running script"
                    failed+=( ${BOOSTER} )
                fi
            else
                log "No script provided. Only refreshed code."
            fi
        done

        echo -e "----------------------------------------------------------------------------------------\n"
        popd > /dev/null
    fi
done

if [ ${#failed[@]} != 0 ]; then
    echo -e "${RED}The following boosters were in error: ${YELLOW}"$(IFS=,; echo "${failed[*]}")
fi
