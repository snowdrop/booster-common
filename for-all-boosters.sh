#!/usr/bin/env bash

# A script to process boosters
set -e

# Defining some colors for output
RED='\033[0;31m'
NC='\033[0m' # No Color
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'

# return value for function that can't return a result
UNDEFINED='__undefined__'

simple_log () {
    echo -e "${BLUE}${1}${NC}"
}

# create a temporary directory WORK_DIR to be removed at the exit of the script
# see: https://stackoverflow.com/questions/4632028/how-to-create-a-temporary-directory
# ====
WORK_DIR=$(mktemp -d)

# check if tmp dir was created
if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
    simple_log "Could not create temp directory"
    exit 1
fi

# deletes the temp directory
function cleanup {
    rm -rf "$WORK_DIR"
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT
# ====


# script-wide toggle controlling pushes from functions
PUSH='on'

# script-wide toggle controlling commits from functions
COMMIT='on'

# script-wide toggle to bypass local changes check
IGNORE_LOCAL_CHANGES='off'

# script-wide toggle to bypass checking out boosters from github
PERFORM_BOOSTER_LOCAL_SETUP='off'

# script-wide toggle to bypass branch existence check, needed to be able to create branches
CREATE_BRANCH='off'

# script-wide toggle to controlling whether input-confirmation will be shown or not
CONFIRMATION_NEEDED='on'

# script-wide toggle to control whether the tests should be executed or not
RUN_TESTS='on'

# boosters directory (where all the local booster copies are located), defaults to working dir
export BOOSTERS_DIR=$(pwd)

# failed boosters
declare -a failed=( )

# skipped boosters
declare -a ignored=( )

# processed boosters
declare -a processed=( )

# boosters which maven project is validated
declare -a validated=( )

# production BOM version
declare _prodBOMVersion

maven_settings() {
    if [[ -z "${MAVEN_SETTINGS}" ]]; then
      echo ""
    else
      echo " --settings ${MAVEN_SETTINGS} "
    fi
}

maven_tests_expression() {
  if [[ "$RUN_TESTS" == on ]]; then
    echo ""
  else
    echo " -DskipTests "
  fi
}

evaluate_mvn_expr() {
    # Evaluate the given maven expression, cf: https://stackoverflow.com/questions/3545292/how-to-get-maven-project-version-to-the-bash-command-line
    result=$(mvn $(maven_settings) -q -Dexec.executable="echo" -Dexec.args='${'${1}'}' --non-recursive exec:exec)
    echo ${result}
}

current_branch() {
    currentBranch=${branch:-$BRANCH}
    echo ${currentBranch}
    unset currentBranch
}

log() {
    echo -e "\t${GREEN}$(current_branch)${BLUE}: ${1}${NC}"
}

log_without_branch() {
    echo -e "\t${BLUE}${1}${NC}"
}

log_ignored() {
   log "${MAGENTA}${1}${MAGENTA}. Ignoring."
   ignoredItem="$(current_branch):${BOOSTER}:\"${1}\""
   ignored+=( "${ignoredItem}" )
}

log_failed() {
   log "${RED}ERROR: ${1}${RED}"
   failedItem="$(current_branch):${BOOSTER}:\"${1}\""
   failed+=( "${failedItem}" )
}

push_to_remote() {
    currentBranch=${branch:-$BRANCH}
    local remoteToPushTo=${1:-$remote}
    options=${2:-}

    if [[ "$PUSH" == on ]]; then
        if git push ${options} "${remoteToPushTo}" "${currentBranch}" > /dev/null; then
            log "Pushed to ${remoteToPushTo}"
        else
            log_ignored "Failed to push to ${remoteToPushTo}"
        fi
    fi
    unset currentBranch
}

commit() {
    if [[ "$COMMIT" == on ]]; then
        log "Commit: '${1}'"
        git commit -q -am "[booster-release] ${1}"
    fi
}

# Commits changes with the specified commit message only if there are local changes. Returns 1 if there are no changes.
commit_if_changed() {
    if [[ $(git status --porcelain) ]]; then
        commit "${1}"
    else
        return 1
    fi
}

compute_new_version() {
    version_expr=${1:-project.version}
    current_version=$(evaluate_mvn_expr ${version_expr})

    parts=( ${current_version//-/ } )
    sb_version=${parts[0]}
    version_int=${parts[1]}
    qualifier=${parts[2]}
    snapshot=${parts[3]}

    # to output parts:
    # echo "${parts[@]}"

    if [[ "$snapshot" == SNAPSHOT ]]
    then
        new_version="${sb_version}-$((version_int +1))-${qualifier}-${snapshot}"
    else
        if [ -n "${qualifier}" ]
        then
            new_version="${sb_version}-$((version_int +1))-${qualifier}"
        else
            new_version="${sb_version}-$((version_int +1))"
        fi
    fi

    echo ${new_version}
}

# Retrieves the latest tag
# Usage: get_latest_tag <on|off to retrieve prod (on) or upstream (off) tag> <git directory path>
get_latest_tag() {
    local -r prod=${1:-off}
    local -r gitDir=${2:-.}
    local regex='^[^v].*[^-redhat]$'
    if [[ "$prod" == on ]]; then
        regex='^[^v].*redhat'
    fi
    local latestTag
    latestTag=$(git tag | grep "${regex}" | sort --version-sort --reverse | head -n1 2> /dev/null)
    if [  $? -eq 0  ]; then
        echo ${latestTag}
    else
        return ${UNDEFINED}
    fi
}

get_next_prod_tag() {
    local -r sbVersion=${1?"get_next_prod_tag <Spring Boot version for which to compute the next tag>"}
    local -r latestTag=$(get_latest_tag on)
    if [[ -z "${latestTag}" ]]; then
        # if we don't have a tag for this specific SB version, then generate it
        echo "${sbVersion}-1-redhat"
    else
        local -r version=$(parse_version ${latestTag} 'own')
        echo "${sbVersion}-$((version +1))-redhat"
    fi
}

# check that first arg is contained in array second arg
# see: https://stackoverflow.com/a/8574392
# returns 0 if found, 1 if not
element_in() {
    local e match="$1"
    shift
    for e; do
        [[ "$e" == "$match" ]] && return 0;
    done
    return 1
}

verify_maven_project_setup() {
    local -r key="${BOOSTER}:${BRANCH}"
    if ! element_in ${key} "${validated[@]}"; then
        mvn $(maven_settings) dependency:analyze > /dev/null
        if [ $? -ne 0 ]; then
            log_failed "Unable to verify that the booster was setup correctly locally - some dependencies seem to be missing"
            # Definitely not the optimal solution for handling errors
            # If we were however to do proper error handling for each booster / branch combination
            # we would need to propagate errors (and perhaps the error types) all the way up the call stack
            # to the main booster / branch control loop
            return 1
        fi
        validated+=( ${key} )
    fi
}

# Changes the version of the current booster to the specified one or computes a new version based on the current one. If changes occurred, commit and push to remote.
# Usage: change_version <new version>
change_version() {
    # The first thing we do is make sure the project's dependencies are valid
    # This is done because if it were not,
    # the change_version function would try to interpret the Maven errors as a Maven version
    # resulting in weird behavior for code that uses the results of changes_version
    # The final error messages that are printed in the console do not provide the user of the script
    # with a clear indication of what went wrong
    verify_maven_project_setup

    local newVersion=${1:-compute}
    local -r expr="project.version"

    # if provided version is "compute" then compute the new version :)
    if [[ "${newVersion}" == compute ]]; then
        newVersion=$(compute_new_version ${expr})
    fi

    local -r currentVersion=$(evaluate_mvn_expr ${expr})
    if mvn $(maven_settings) versions:set -DnewVersion=${newVersion} > /dev/null; then
        # Only attempt committing if we have changes otherwise the script will exit
        if commit_if_changed "Update version to ${newVersion}"; then
            push_to_remote
        else
            log_ignored "Version was already at ${YELLOW}${newVersion}"
        fi

        find . -name "*.versionsBackup" -delete
    else
        log_failed "Couldn't set version. Reverting to remote ${remote} version."
        git reset --hard "${remote}"/"${BRANCH}"
    fi
}

setup_booster_locally () {
    local booster_name=${1}
    local booster_git_url=${2}

    log_without_branch "Setting up locally"

    if [ ! -d "${booster_name}" ]; then
      git clone -q -o ${remote} ${booster_git_url} > /dev/null 2>&1
      pushd ${booster_name} > /dev/null
    else
      pushd ${booster_name} > /dev/null
      git fetch --tags -q ${remote}
      BRANCH=$(git rev-parse --abbrev-ref HEAD)
      revert "log_without_branch" true
      unset BRANCH
    fi

    for branch in ${branches[@]}
    do
      if git show-ref -q refs/heads/${branch}; then
        git checkout -q ${branch}
        git reset -q --hard ${remote}/${branch}
        git clean -f -d
      else
        if git ls-remote --heads --exit-code ${booster_git_url} ${branch} > /dev/null; then
          git checkout -q --track ${remote}/${branch}
        fi
      fi
    done

    popd > /dev/null
    unset branch
}

create_branch() {
    local -r branch=${1:-$BRANCH}

    if git ls-remote --heads "${remote}" "${branch}" | grep "${branch}" > /dev/null;
    then
        log_ignored "Branch already exists on remote"
    else
        if ! git checkout -b ${branch} > /dev/null 2> /dev/null;
        then
            log_failed "Couldn't create branch"
            return 1
        fi

        push_to_remote "${remote}"
    fi
}

delete_branch() {
    local -r branch=${1:-$BRANCH}

    if git ls-remote --heads "${remote}" "${branch}" | grep "${branch}" > /dev/null;
    then
        log "Are you sure you want to delete ${YELLOW}${branch}${BLUE} branch on remote ${YELLOW}${remote}${BLUE}?"
        log "Press any key to continue or ctrl-c to abort."
        read foo

        push_to_remote "${remote}" "--delete"
    else
        log_ignored "Branch doesn't exist on remote"
    fi

    if ! git branch -D "${branch}" > /dev/null 2> /dev/null;
    then
        log_ignored "Branch doesn't exist locally"
    fi
}

find_openshift_templates() {
  echo $(find . -path "*/.openshiftio/application.yaml")
}

replace_template_placeholders() {
  local file=${1}
  local booster_version=${2}

  sed -i.bak -e "s/BOOSTER_VERSION/${booster_version}/g" ${file}
  log "${YELLOW}${file}${BLUE}: Replaced BOOSTER_VERSION token by ${booster_version}"

  rm ${file}.bak
}

# Extracts the image that is used in a template
# assumes that the ImageStream name starts with 'runtime'
# and the tag containing the image is named 'RUNTIME_VERSION'
# An example output could be: registry.access.redhat.com/redhat-openjdk-18/openjdk18-openshift
get_image_from_template() {
  local file=${1}
  echo $(yq -r '.objects[] | select(.kind == "ImageStream") | select(.metadata.name | startswith("runtime")) | .spec.tags[] | select(.name == "RUNTIME_VERSION") | .from.name' ${file} | cut -f1 -d":")
}

# Determines what the highest tag is for an image
# The image must be in the following format registryUrl/imageOwner/imageName,
# for example: registry.access.redhat.com/redhat-openjdk-18/openjdk18-openshift
# TODO: add caching of results
determine_highest_runtime_version_of_image() {
  local registryUrl=$(echo "${1}" | cut -f1 -d"/")
  local imageOwner=$(echo "${1}" | cut -f2 -d"/")
  local imageName=$(echo "${1}" | cut -f3 -d"/")
  echo $(curl -s -L http://${registryUrl}/v2/${imageOwner}/${imageName}/tags/list | jq -r  '.tags | sort | reverse | del(.[0]) | first')
}

# Determines what the highest tag is for the runtime image in the template
# See get_image_from_template and determine_highest_runtime_version_of_image
determine_highest_runtime_version_of_image_in_template() {
  local file=${1}
  local imageFromFile=$(get_image_from_template ${file})
  echo $(determine_highest_runtime_version_of_image ${imageFromFile})
}


# WARNING This method aside from replacing the RUNTIME_VERSION value, also normalizes the YAML
# Unfortunately we can't control that due the implicit yaml to json to yaml conversions
replace_template_runtime_version() {
  local -r file=${1}
  local -r version=${2}

  local -r newParams=$(yq '.parameters |  map(if .name == "RUNTIME_VERSION" then . + {"value": "'"${version}"'"} else . end)' ${file})
  yq -y '.parameters='"${newParams}" ${file} > ${file}.new
  rm ${file}
  mv ${file}.new ${file}
}

# Meant to be called using 'fn replace_template_runtime_version_of_booster 1.3-9'
replace_template_runtime_version_of_booster() {
    local -r newVersion=${1}
    if [ -z "$newVersion" ]
    then
      log_ignored "A version number must be supplied"
      return 1
    fi

    # replace template placeholders if they exist
    templates=($(find_openshift_templates))
    if [ ${#templates[@]} != 0 ]; then
        for file in ${templates[@]}
        do
            replace_template_runtime_version ${file} ${newVersion}
        done
        if commit_if_changed "Update template's RUNTIME_VERSION -> ${newVersion}"; then
            push_to_remote
        else
            # if no changes were made it means that templates don't contain tokens and should be fixed
            log_ignored "Couldn't replace tokens in templates"
            return 1
        fi
    fi
}

# Extracts the possible components of a Snowdrop artifact version (BOM / booster) from specified version string
# Usage: parse_version <version string to parse> [sb | own | qualifier | snapshot | components] (defaults to 'components')
# where, given, for example, the '1.5.14-2-redhat-SNAPSHOT' version string
#   sb          -> Spring Boot version                                          => '1.5.14'
#   own         -> Artifact own version                                         => '2'
#   qualifier   -> Artifact qualifier if it exists, empty otherwise             => 'redhat'
#   snapshot    -> "SNAPSHOT" if the artifact is a snapshot, empty otherwise    => 'SNAPSHOT'
#   components  -> Array of the above components as strings                     => ('1.5.14' '2' 'redhat' 'SNAPSHOT')
# based on https://stackoverflow.com/a/10583562 for the components result.
# Note that to retrieve the components, just `eval` the function and it will make produce `components` array containing the version components
# eval $(parse_version 1.5.13-2-SNAPSHOT)
# For single component retrieval, regular evaluation can be used:
# local -r sbVersion=$(parse_version 1.5.13-2-SNAPSHOT sb) will evaluate to '1.5.13'
parse_version() {
    local -r currentVersion=${1}
    local -r extract=${2:-components}

    local -r versionRE='([1-9].[0-9].[0-9]+)-([0-9]+)-?([a-zA-Z0-9]+)?-?(SNAPSHOT)?'
    if [[ "${currentVersion}" =~ ${versionRE} ]]; then
        local -r sbVersion=${BASH_REMATCH[1]}
        local -r versionInt=${BASH_REMATCH[2]}
        local -r qualifier=${BASH_REMATCH[3]}
        local -r snapshot=${BASH_REMATCH[4]}
        case "$extract" in
            sb)
                echo ${sbVersion}
            ;;
            own)
                echo ${versionInt}
            ;;
            qualifier)
                echo ${qualifier}
            ;;
            snapshot)
                echo ${snapshot}
            ;;
            components)
                local -r components=( "${sbVersion}" "${versionInt}" "${qualifier}" "${snapshot}" )
                declare -p components
            ;;
            *)
                simple_log "Unknown extraction component: '${extract}'" 1>&2
                return 1
            ;;
        esac
    else
        log_failed "${YELLOW}${currentVersion}${BLUE} does not match expected version format"
        return 1
    fi
}

# Based on https://stackoverflow.com/a/4025065
# Returns 0 if both versions are equal, 1 if the first argument is greater, 2 if the second argument is greater
version_compare() {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for (( i = ${#ver1[@]}; i < ${#ver2[@]}; i ++ ))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++ ))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

release() {
    verify_maven_project_setup

    local -r currentVersion=$(evaluate_mvn_expr 'project.version')

    local -r pncBuildQualifier=${1:-CR1}

    if [[ "${currentVersion}" != *-SNAPSHOT ]]; then
        log_ignored "Cannot release a non-snapshot version"
        return 1
    fi

    local -a components
    eval $(parse_version ${currentVersion})
    local -r sbVersion=${components[0]}
    local -r versionInt=${components[1]}
    local -r newVersionInt=$((versionInt + 1))
    local qualifier=${components[2]}
    local snapshot=${components[3]}

    # check that booster version is greater than latest tag
    local latestTag=$(get_latest_tag)
    if [ "${latestTag}" != $UNDEFINED ]; then
        local -r tagSBVersion=$(parse_version ${latestTag} sb)
        local error=0
        # first check SB version
        version_compare ${tagSBVersion} ${sbVersion}
        case $? in
            1)
                error=1
            ;;
            0)
            # if SB versions are equal, check sub-version
                local -r tagVersion=${BASH_REMATCH[2]}
                if ((tagVersion >= versionInt)); then
                    error=1
                fi
            ;;
        esac
        if ((error == 1)); then
            log_failed "Booster version '${YELLOW}${currentVersion}${RED}' is older than latest released version '${YELLOW}${latestTag}${RED}'"
            return 1
        fi
    else
        log "Booster has never been released! Creating first release."
    fi


    # needed because when no qualifier exists, the regex captures this is different order
    if [ -z ${snapshot} ] && [ "$qualifier" == SNAPSHOT ]; then
        qualifier=""
        snapshot="SNAPSHOT"
    fi

    if [[ ! -z ${qualifier} ]]; then
        local -r allowedQualifiers=(redhat rhoar)
        if [[ ! " ${allowedQualifiers[@]} " =~ " ${qualifier} " ]]; then
            # when there is a qualifier present and it's not one of the allowed values, fail
            log_ignored "Qualifier ${qualifier} is not allowed. Please check the version of the booster"
            return 1
        fi
    fi

    releaseVersion="${sbVersion}-${versionInt}"
    if [[ -n "${qualifier}" ]]; then
        releaseVersion="${releaseVersion}-${qualifier}"
    fi

    nextVersion="${sbVersion}-${newVersionInt}"
    if [[ -n "${qualifier}" ]]; then
        nextVersion="${nextVersion}-${qualifier}"
    fi
    nextVersion="${nextVersion}-SNAPSHOT"

    if git ls-remote --tags "${remote}" "${releaseVersion}" | grep "${releaseVersion}" > /dev/null;
    then
      log_ignored "Tag ${releaseVersion} already exists. Please make sure that the booster version is set correctly"
      return 1
    fi

    # replace template placeholders if they exist
    templates=($(find_openshift_templates))
    if [ ${#templates[@]} != 0 ]; then
        for file in ${templates[@]}
        do
            replace_template_placeholders ${file} ${releaseVersion}
        done
        if ! commit_if_changed "Replaced templates placeholders: BOOSTER_VERSION -> ${releaseVersion}"; then
            # if no changes were made it means that templates don't contain tokens and should be fixed
            log_ignored "Couldn't replace tokens in templates"
            return 1
        fi
    fi

    # switch off pushing since we'll do it at the end
    PUSH='off'
    change_version ${releaseVersion}

    log "Creating tag ${YELLOW}${releaseVersion}"
    git tag -a ${releaseVersion} -m "Releasing ${releaseVersion}" > /dev/null

    if [ ${#templates[@]} != 0 ]; then
        # restore template placeholders
        for file in ${templates[@]}
        do
            sed -i.bak -e "s/${releaseVersion}/BOOSTER_VERSION/g" ${file}
            log "${YELLOW}${file}${BLUE}: Restored BOOSTER_VERSION token"

            rm ${file}.bak
        done
        commit_if_changed "Restored templates placeholders: ${releaseVersion} -> BOOSTER_VERSION"
    fi

    change_version ${nextVersion}

    if ! prod_tag ${sbVersion} ${pncBuildQualifier}; then
      log_failed "Couldn't create the productized tag"
      return 1
    fi

    # switch pushing back on and push
    PUSH='on'
    push_to_remote "${remote}" "--tags"
}

get_prod_BOM_version() {
    local -r sbVersion=${1?"Usage prod_tag <spring boot version to release>"}
    local -r pncBuildQualifier=${2:-CR1}

    if [ -z "${_prodBOMVersion}" ]; then
        _prodBOMVersion=$(curl -sS http://rcm-guest.app.eng.bos.redhat.com/rcm-guest/staging/rhoar/spring-boot/spring-boot-${sbVersion}.${pncBuildQualifier}/extras/repository-artifact-list.txt | grep spring-boot-bom)
        if [ $? -ne 0 ]; then
           log_failed "Couldn't retrieve the prod BOM version. Are you connected to the VPN?" 1>&2
           echo "${UNDEFINED}"
        fi
        _prodBOMVersion=$(echo "${_prodBOMVersion}" | cut -d: -f3)
    fi
    echo ${_prodBOMVersion}
}

prod_tag() {
    local -r sbVersion=${1?"Usage prod_tag <spring boot version to release>"}
    local -r pncBuildQualifier=${2:-CR1}

    # fail if we're not on master branch
    local -r branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "${branch}" != master ]; then
        log_failed "Cannot create prod tag if not on master branch"
        return 1
    fi

    ## create prod tag
    # compute tag name
    local -r nextProdTag=$(get_next_prod_tag "${sbVersion}")
    # create ephemeral branch to anchor tag
    local -r ephemeralBranch="${nextProdTag}-branch"
    git checkout -b "${ephemeralBranch}" >/dev/null 2>/dev/null
    log "Switched to ${YELLOW}${ephemeralBranch}${BLUE} branch"
    # update project version
    change_version ${nextProdTag}

    # update templates with proper version
    if [ ${#templates[@]} != 0 ]; then
        for file in ${templates[@]}
        do
            replace_template_placeholders ${file} ${nextProdTag}
        done
        if ! commit_if_changed "Replaced templates placeholders: BOOSTER_VERSION -> ${nextProdTag}"; then
            # if no changes were made it means that templates don't contain tokens and should be fixed
            log_ignored "Couldn't replace tokens in templates"
            return 1
        fi
    fi

    # update the pom to use the proper prod BOM version
    # retrieve the prod BOM version: requires being connected to VPN
    local -r prodBOMVersion=$(get_prod_BOM_version ${sbVersion} ${pncBuildQualifier})
    if [ "${prodBOMVersion}" == "${UNDEFINED}" ]; then
        return 1
    fi
    set_maven_property "spring-boot-bom.version" ${prodBOMVersion}
    commit_if_changed "Update BOM to version ${prodBOMVersion}"

    # update the Spring Boot version property (which might be redundant if we're just releasing a new version of the booster)
    local -r sbReleaseVersion="${sbVersion}.RELEASE"
    set_maven_property "spring-boot.version" ${sbReleaseVersion}
    commit_if_changed "Update Spring Boot to version ${sbReleaseVersion}"

    log "Creating tag ${YELLOW}${nextProdTag}"
    git tag -a ${nextProdTag} -m "Releasing ${nextProdTag}" > /dev/null

    # switch back to master and delete ephemeral branch
    git checkout ${branch} >/dev/null 2>/dev/null
    git branch -D "${ephemeralBranch}"
}

do_revert() {
  local -r silence=${1:-false}
  local general_git_options=""
  if ${silence} ; then
    general_git_options=" -q ${general_git_options} "
  fi

  git reset  ${general_git_options} --hard "${remote}"/"${BRANCH}"
  git clean ${general_git_options} -f -d
}

# Asks to confirm the action passed as first argument and returns the value the user passed or `Y` if confirmation is skipped.
# Based on https://stackoverflow.com/a/1989633
# Note that it's important to send all output to `stderr / &2` since otherwise it interferes with the return value
confirm() {
    local answer='N'
    local action=${1:-revert}

    if [[ "$CONFIRMATION_NEEDED" == on ]]; then
        log "Are you sure you want to ${action}?" >&2
        log "${RED}YOU WILL LOSE ALL UNPUSHED LOCAL COMMITS SO BE CAREFUL!" >&2
        log "Press ${RED}Y to ${action}${BLUE} or ${YELLOW}any other key to leave the booster as-is." >&2
        read answer
    else
        answer='Y'
    fi

    echo ${answer}
}

revert() {
    log_function=${1:-"log"}
    local -r silence_git=${2:-false}
    if [[ $(git status --porcelain) ]]; then
        ${log_function} "${RED}DANGER: YOU HAVE UNCOMMITTED CHANGES:"
        git status --porcelain
    fi

    local -r answer=$(confirm)
    if [ "${answer}" == Y ]; then
        ${log_function} "Resetting to remote ${remote} state"
        do_revert ${silence_git}
    else
        ${log_function} "Leaving as-is"
    fi
}

fmp_deploy() {
  mvn $(maven_settings) -q -B -DskipTests=true clean compile fabric8:deploy -Popenshift ${MAVEN_EXTRA_OPTS:-}
}

s2i_deploy() {
    templates=($(find_openshift_templates))
    for file in ${templates[@]}
    do
        replace_template_placeholders ${file} 'latest'
        oc apply -f ${file}
        oc new-app --template=$(yq -r .metadata.name ${file}) -p SOURCE_REPOSITORY_URL="https://github.com/snowdrop/${BOOSTER}" -p SOURCE_REPOSITORY_REF=${BRANCH}
        sleep 30 # needed in order to bypass the 'Pending' state
        timeout 300s bash -c 'while [[ $(oc get pod -o json | jq  ".items[] | select(.metadata.name | contains(\"build\"))  | .status  " | jq -rs "sort_by(.startTme) | last | .phase") == "Running" ]]; do sleep 20; done; echo ""'
    done
}

create_namespace() {
  local namespace_name=${1}
  oc delete project ${namespace_name} --ignore-not-found=true
  while [[ ! -z $(oc get namespaces -o json | jq  -r ".items[] | select(.metadata.name == \"${namespace_name}\") | .status.phase") ]]; do sleep 5; done;
  oc new-project ${namespace_name} > /dev/null
}

delete_namespace() {
  local namespace_name=${1}
  oc delete project ${namespace_name} > /dev/null
}


run_integration_tests() {
    if [[ "$RUN_TESTS" == on ]]; then
      local canonical_name="${BOOSTER}"
      local deployment_type=${1:-'fmp_deploy'}

      log "Running tests of booster ${canonical_name} from directory: ${PWD}"

      create_namespace ${canonical_name}

      log "Deploying using ${deployment_type}"
      ${deployment_type}

      if [ $? -ne 0 ]; then
        log_ignored "Deployment type '${deployment_type}' is not valid"
        delete_namespace ${canonical_name}
        return
      fi
      mvn $(maven_settings) -q -B clean verify -Dfabric8.skip=true -Denv.init.enabled=false -Popenshift,openshift-it ${MAVEN_EXTRA_OPTS:-}
      if [ $? -eq 0 ]; then
          echo
          log "Successfully tested"
          #Delete the project since there is no need to inspect the results when everything is OK
          delete_namespace ${canonical_name}
          # Make sure we cleanup
          do_revert
      else
          log_failed "Tests failed: inspecting the '${canonical_name}' namespace might provide some insights"

          #We don't delete the project because it could be needed for a postmortem inspection
      fi
    fi
}

run_smoke_tests() {
    if [[ "$RUN_TESTS" == on ]]; then
      log "Running tests of booster from directory: ${PWD}"
      mvn $(maven_settings) -q -B clean verify ${MAVEN_EXTRA_OPTS:-}
      if [ $? -eq 0 ]; then
          log "Successfully tested"
      else
          log_failed "Tests failed"
      fi
    fi
}

get_catalog_dir() {
    echo "${WORK_DIR}/launcher-booster-catalog"
}

prepare_catalog() {
    # clone launcher-catalog in temp dir if it doesn't already exist
    local -r catalogDir=$(get_catalog_dir)
    local -r officialBranchName="official"
    if [[ ! -d  ${catalogDir} ]]; then
        simple_log "Preparing launcher-booster-catalog temporary clone, checking out ${YELLOW}official${BLUE} branch. Only done once." 1>&2
        if ! git clone -b ${officialBranchName} git@github.com:snowdrop/launcher-booster-catalog.git ${catalogDir} 1>&2 2> /dev/null; then
            simple_log "Could not clone launcher-booster-catalog"
            return 1
        fi
        # make sure that our copy is up-to-date with upstream version and create a branch
        pushd ${catalogDir} > /dev/null
        git remote add upstream git@github.com:fabric8-launcher/launcher-booster-catalog.git 1>&2 2> /dev/null
        git pull --rebase upstream master 1>&2 > /dev/null 2> /dev/null
        git push origin ${officialBranchName} 1>&2 > /dev/null 2> /dev/null
        popd > /dev/null
    fi

    echo ${catalogDir}
}

catalog() {
    local -r newSBVersion=${1?"Usage catalog <Spring Boot version associated with this update>"}
    _catalog ${newSBVersion} "master"
    _catalog ${newSBVersion} "redhat"
}

_catalog() {
    local -r newSBVersion=${1?"Usage catalog <Spring Boot version associated with this update>"}
    local -r branch=${2:-$BRANCH}
    declare -Ar catalog_branch_mapping=( ["master"]="current-community" ["redhat"]="current-redhat" ["osio"]="current-osio" )
    declare -Ar catalog_booster_mapping=( ["http"]="rest-http" ["http-secured"]="rest-http-secured" )

    local -r simpleName=$(simple_name)
    # get the catalog project
    local -r catalogDir=$(get_catalog_dir)
    if [ $? -ne 0 ]; then
        log_failed "Unable to retrieve launcher-booster-catalog"
        return 1
    fi

    # get the YAML file for the booster / branch combination
    local -r catalogVersion=${catalog_branch_mapping[${branch}]}
    if [[ ! -n ${catalogVersion} ]]; then
        log_ignored "No mapping exist for branch ${YELLOW}${branch}"
        return 1
    fi
    local catalogMission=${catalog_booster_mapping[${simpleName}]}
    if [[ ! -n ${catalogMission} ]]; then
        # if we don't have a booster mapping, use the booster simple name
        catalogMission=${simpleName}
    fi

    local -r boosterYAML="${catalogDir}/spring-boot/${catalogVersion}/${catalogMission}/booster.yaml"
    if [[ ! -f ${boosterYAML} ]]; then
        log_failed "Couldn't find ${boosterYAML}"
        return 1
    fi

    local newVersion
    case ${branch} in
        redhat)
            newVersion=$(get_latest_tag on "${BOOSTERS_DIR}/${BOOSTER}")
        ;;
        *)
            newVersion=$(get_latest_tag off "${BOOSTERS_DIR}/${BOOSTER}")
        ;;
    esac

    # update metadata.yaml if we haven't already done it
    local -r metadataYAML=${catalogDir}"/metadata.yaml"
    if [[ ! $(git -C ${catalogDir} status --porcelain ${metadataYAML}) ]]; then
        local oldVersion=$(yq -r .source.git.ref ${boosterYAML})
        local -r oldSBVersion=$(parse_version ${oldVersion} sb)

        version_compare ${newSBVersion} ${oldSBVersion}
        if (( $? == 1 )); then
            local -r newSBVersions=$(yq '.runtimes[] | select(.id == "spring-boot") | .versions | map(if .id == "current-community" then .name="'"${newSBVersion}"'.RELEASE (Community)" elif .id == "current-redhat" then .name="'"${newSBVersion}"'.RELEASE (RHOAR)" else . end)' ${metadataYAML})
            local -r newRuntimes=$(yq '.runtimes | map(if .id == "spring-boot" then .versions = '"${newSBVersions}"' else . end)' ${metadataYAML})
            yq -y '.runtimes='"${newRuntimes}" ${metadataYAML} > ${metadataYAML}.new
            rm ${metadataYAML}
            mv ${metadataYAML}.new ${metadataYAML}
        fi
    fi


    yq -y '.source.git.ref="'"${newVersion}"'"' ${boosterYAML} > ${boosterYAML}.new
    rm ${boosterYAML}
    mv ${boosterYAML}.new ${boosterYAML}
}

open_catalog_pr() {
    local -r sbVersion=${1?"Must provide a Spring Boot version"}
    local -r catalogDir=$(get_catalog_dir)
    pushd ${catalogDir} > /dev/null
    local -r branchName="update-to-${sbVersion}"
    git checkout -b "${branchName}" > /dev/null 2> /dev/null
    commit "Update Spring Boot to ${sbVersion}"
    local -r pr=$(hub pull-request -p -h snowdrop:"${branchName}" -b fabric8-launcher:master -m "DO NOT MERGE: Update Spring Boot to ${sbVersion}")
    simple_log "Created PR: ${YELLOW}${pr}"
    popd > /dev/null
}

trim() {
    # trim leading and trailing whitespaces using https://stackoverflow.com/a/3232433
    local toTrim=$(echo "$@")
    echo -e "${toTrim}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

run_cmd() {
    # build command: since arguments are passed unquoted, we need a separator to mark the command from the commit message
    # we use ---- as separator so we expect arguments to be in the form "cmd ---- msg"
    # first build a string from all arguments
    local cmdAndMsg=$(echo "$@")
    # then we extract parts using https://stackoverflow.com/a/10520718 trimming leading and trailing whitespaces
    local cmd=$(trim ${cmdAndMsg%----*})
    local msg=$(trim ${cmdAndMsg##*----})

    log "Executing ${YELLOW}'${cmd}'"

    if ! eval ${cmd}; then
        log_failed "${cmd} command failed"
        return 1
    fi

    if [ -n "$msg" ]; then
        # we have a commit message so commit and push result of command if that resulted in local changes
        if commit_if_changed "${msg}"; then
            push_to_remote
        fi
    fi
}

revert_release() {
    # first check we have a tag
    local tag=$(get_latest_tag)
    if [ "${tag}" != $UNDEFINED ]; then

        # release process creates 4 commits that we need to revert
        git revert --no-commit HEAD~4..
        local -r previousSHA=$(git rev-list HEAD~5..HEAD~4)
        local -r previousMsg=$(git log -1 --format="%h: %s" ${previousSHA})
        log "About to revert state to commit -> ${previousMsg}"

        # ask confirmation before reverting
        local answer=$(confirm "revert to before last release")
        if [ "${answer}" == Y ]; then
            commit "Revert to ${previousMsg}"
            push_to_remote

            # delete tag
            delete_tag ${tag}

            tag=$(get_latest_tag on)
            delete_tag ${tag}
        else
            git revert --abort
            log "Revert aborted"
        fi
    else
        log_failed "Booster hasn't been tagged: no release to revert!"
    fi
}

# Deletes the specified tag both locally and remotely (if push is activated)
delete_tag() {
    local -r tag=${1?"Usage: delete_tag <tag name>"}
    local answer=$(confirm "delete ${tag} locally and on remote")
    if [ "${answer}" == Y ]; then
        if [[ "$PUSH" == on ]]; then
            git push --delete ${remote} ${tag}
        fi
        git tag -d ${tag}
    else
        log "Tag deletion aborted"
    fi
}

set_maven_property() {
    local -r propertyName=${1}
    local -r propertyValue=${2}
    local -r runVerificationBuild=${3:-false}

    # We are using perl to do all replacements since we need to make sure that we only replace the first occurrence in the file
    # See https://stackoverflow.com/a/6278174/2504224

    if ! xq -e '.project.properties' pom.xml > /dev/null; then

      if xq -e '.project.dependencies' pom.xml > /dev/null; then
        # add an empty properties section right before the dependencies section
        perl -pi.bak -e '!$x && s/<dependencies>/<properties>\n  <\/properties>\n\n  <dependencies>/g && ($x=1)' pom.xml
      elif xq -e '.project.description' pom.xml > /dev/null; then
        # add an empty properties section right after the description section
        perl -pi.bak -e '!$x && s/<\/description>/<\/description>\n\n  <properties>\n  <\/properties>/g && ($x=1)' pom.xml
      else
        # add an empty properties section right after the artifactId section
        perl -pi.bak -e '!$x && s/<\/artifactId>/<\/artifactId>\n\n  <properties>\n  <\/properties>/g && ($x=1)' pom.xml
      fi

    fi

    local wasAdded=0
    if ! grep --quiet "<${1}>" pom.xml; then
      # add the property as the last property in the properties section with a dummy value
      perl -pi.bak -e "!\$x && s/<\/properties>/  <${propertyName}>replaceme<\/${propertyName}>\n  <\/properties>/g && (\$x=1)" pom.xml
      wasAdded=1
    fi

    # replace the actual property
    perl -pi.bak -e "!\$x && s/${propertyName}>.*</${propertyName}>${propertyValue}</g && (\$x=1)" pom.xml

    rm pom.xml.bak

    # Only attempt committing if we have changes
    if [[ $(git status --porcelain) ]]; then
      if [ "$runVerificationBuild" = true ] ; then
        log "Running verification build"
        if mvn $(maven_settings) $(maven_tests_expression) clean verify > build.log; then
          log "Build ${YELLOW}OK"
          rm build.log

          local addedOrSetLog="changed"
          local addedOrSetCommit="Update"
          if (( wasAdded == 1 )); then
            addedOrSetLog="added and set"
            addedOrSetCommit="Add"
          fi
          log "Property ${propertyName}${BLUE} ${addedOrSetLog} to ${YELLOW}${propertyValue}"
          commit "${addedOrSetCommit} ${propertyName} version with ${propertyValue} value"
          push_to_remote
        else
          log_failed "Build failed! Check ${YELLOW}build.log"
          log "You will need to reset the branch or explicitly set the parent before running this script again."
        fi
      fi
    else
      log_ignored "Property ${propertyName} was not changed"
    fi
}

show_help () {
    simple_log "This scripts executes the given command on all local boosters (identified by the 'spring-boot-*-booster' pattern) found in the current directory."
    simple_log "Usage:"
    simple_log "    -b                            A comma-separated list of branches. For example ${YELLOW}-b branch1,branch2${BLUE}. Defaults to ${YELLOW}$(IFS=,; echo "${default_branches[*]}")${BLUE}. Note that this option is mandatory to create / delete branches."
    simple_log "    -q                            Github query string used to identify potential boosters to operate on. Defaults to ${YELLOW}${default_github_query}${BLUE}."
    simple_log "    -d                            Toggle dry-run mode: no commits or pushes. This operation is not compatible with the release command."
    simple_log "    -f                            Bypass check for local changes, forcing execution if changes exist."
    simple_log "    -h                            Display this help message."
    simple_log "    -l                            Specify where the local copies of the boosters should be found. Defaults to current working directory."
    simple_log "    -m                            The boosters to operate on (comma separated value). Boosters are effectively white-listed in this mode. The name of each booster is the simple booster name (for example: ${YELLOW}circuit-breaker${BLUE}). ${MAGENTA}This can't be used together with the ${YELLOW}-x${MAGENTA} option."
    simple_log "    -x                            The boosters to exclude (comma separated value). Boosters are effectively black-listed in this mode. The name of each booster is the simple booster name (for example: ${YELLOW}circuit-breaker${BLUE}). ${MAGENTA}This can't be used together with the ${YELLOW}-m${MAGENTA} option."
    simple_log "    -n                            Skip confirmation dialogs."
    simple_log "    -p                            Perform booster local setup."
    simple_log "    -r                            The name of the git remote to use for the boosters, for example upstream or origin. The default value is ${YELLOW}${default_remote}${BLUE}."
    simple_log "    -s                            Skip the test execution."
    simple_log "    release                       Release the boosters."
    simple_log "    change_version <args>         Change the project version. Run with ${YELLOW}-h${BLUE} to see help."
    simple_log "    run_integration_tests <deployment type>  Run the integration tests on an OpenShift cluster. Requires to be logged in to the required cluster before executing. Deployment Type can be either ${YELLOW}fmp_deploy${BLUE} (default) or ${YELLOW}s2i_deploy${BLUE}."
    simple_log "    create_branch                 Create a branch specified by the ${YELLOW}-b${BLUE} option. Those branches cannot be any of the protected branches. The new branch is always created off of master"
    simple_log "    delete_branch                 Delete a branch specified by the ${YELLOW}-b${BLUE} option. Those branches cannot be any of the protected branches"
    simple_log "    cmd <command>                 Execute the provided shell command. The following environment variables can be used by the scripts: ${YELLOW}BOOSTER, BOOSTER_DIR, BRANCH${BLUE}. Run with ${YELLOW}-h${BLUE} to see help."
    simple_log "    fn <function name>            Execute the specified function. This allows to call internal functions. Make sure you know what you're doing!"
    simple_log "    revert                        Revert the booster state to the last remote version."
    simple_log "    script <path to script>       Run provided script."
    simple_log "    run_smoke_tests               Run the unit tests locally."
    simple_log "    set_maven_property <property name> <property value>           Set a Maven property. Works whether the property exists or not (even if the properties section does not exist). Commits the changes by default. Use ${YELLOW}-v${BLUE} to run a verification build after the property is updated."
    simple_log "    catalog <Spring Boot version> Creates a pull-request to update the launcher-booster-catalog project with the latest booster versions corresponding to the specified Spring Boot version."
    echo
}

show_change_version_help() {
    simple_log "change_version command changes the project's version"
    simple_log "Usage:"
    simple_log "    -h                            Display this help message."
    simple_log "    -v <version name>             Optional: specify which version to use. Version is computed otherwise."
}

show_cmd_help() {
    simple_log "cmd command executes the specified command on the project, optionally committing and pushing the changes to the remote repository (using the -p flag)."
    simple_log "Commands can use the BOOSTER, BOOSTER_DIR, BRANCH environment variables to get information about the currently processed booster"
    simple_log "Usage:"
    simple_log "    -h                            Display this help message."
    simple_log "    -p <commit message>           Optional: commit the changes (if any) and pushes them to the remote repository."
}

show_set_maven_property_help() {
    simple_log "set_maven_property <property_name> <property_value> Updates a maven property in pom.xml. The commands works whether or not the property exists"
    simple_log "Options:"
    simple_log "    -h                            Display this help message."
    simple_log "    -v                            Optional: Run a verification build after setting the property"
}


error() {
    echo -e "${RED}Error: ${1}${NC}"
    local help=${2:-show_help}
    ${help}
    exit ${3:-1}
}

simple_name() {
    if [[ ${BOOSTER} =~ spring-boot-(.*)-booster ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}


### script main ###
if [ $# -eq 0 ]; then
    show_help
fi

readonly default_branches=("master")
branches=("${default_branches[@]}")

readonly default_remote=upstream
remote=${default_remote}

declare -a explicitly_selected_boosters=( )
# zero means that no selection type has been make (and therefore all boosters will be operated on)
# a negative value means that all boosters except the explicitly selected ones will be operated on
# a positive value means that only the explicitly selected boosters will be operated on
selection_type=0

readonly default_github_query="org:snowdrop+topic:booster"
github_query=${default_github_query}

# See https://sookocheff.com/post/bash/parsing-bash-script-arguments-with-shopts/
while getopts ":hdnfspq:b:r:m:x:l:" opt; do
    case ${opt} in
        h)
            show_help
            exit 0
        ;;
        d)
            echo -e "${YELLOW}== DRY-RUN MODE ACTIVATED: no commits or pushes will be issued ==${NC}"
            echo
            PUSH='off'
            COMMIT='off'
        ;;
        f)
            echo -e "${YELLOW}== BYPASSING CHECK FOR LOCAL CHANGES ==${NC}"
            echo
            IGNORE_LOCAL_CHANGES='on'
        ;;
        l)
            # check that target directory exists, if not create it
            if [ ! -d "$OPTARG" ]; then
                mkdir -p $OPTARG
            fi
            # See https://stackoverflow.com/questions/11621639/how-to-expand-relative-paths-in-shell-script/11621788 on how to
            # resolve relative directories to the current working dir.
            BOOSTERS_DIR=$(cd $OPTARG; pwd)
            echo -e "${YELLOW}== Will use directory ${BLUE}${BOOSTERS_DIR}${YELLOW} as the booster parent directory ==${NC}"
            echo
        ;;
        b)
            IFS=',' read -a branches <<< "$OPTARG"
            echo -e "${YELLOW}== Will use '${BLUE}$OPTARG${YELLOW}' branch(es) instead of the default ${BLUE}'$(IFS=,; echo "${default_branches[*]}")${YELLOW}' ==${NC}"
            echo
        ;;
        q)
            github_query="$OPTARG"
            echo -e "${YELLOW}== Will use '${BLUE}${github_query}${YELLOW}' as the Github query that identifies potential boosters instead of the default '${default_github_query}' ==${NC}"
            echo
        ;;
        p)
            echo -e "${YELLOW}== Will clone boosters from GitHub - This will result in the loss of any local changes to the boosters ==${NC}"
            echo
            PERFORM_BOOSTER_LOCAL_SETUP='on'
        ;;
        r)
            echo -e "${YELLOW}== Will use '${BLUE}$OPTARG${YELLOW}' as the git remote instead of the default of ${BLUE}'${default_remote}${YELLOW}' ==${NC}"
            echo
            remote=$OPTARG
        ;;
        n)
            echo -e "${YELLOW}== SKIP CONFIRMATION DIALOGS ACTIVATED: no confirmation will be requested from the user for any potentially destructive operations ==${NC}"
            echo
            CONFIRMATION_NEEDED='off'
        ;;
        s)
            echo -e "${YELLOW}== SKIPPING TEST EXECUTION. No tests will be run for boosters ==${NC}"
            echo
            RUN_TESTS='off'
        ;;
        m)
            if [ ${#explicitly_selected_boosters[@]} -ne 0 ]; then
              echo -e "${RED}== Using '-m' and '-x' together is not supported since it doesn't make sense  ==${NC}"
              exit 1
            fi
            IFS=',' read -r -a explicitly_selected_boosters <<< "$OPTARG"
            selection_type=1

            echo -e "${YELLOW}== Will use only the following booster(s): '${BLUE}$OPTARG${YELLOW}' ==${NC}"
            echo
        ;;
        x)
            if [ ${#explicitly_selected_boosters[@]} -ne 0 ]; then
              echo -e "${RED}== Using '-m' and '-x' together is not supported since it doesn't make sense  ==${NC}"
              exit 1
            fi
            IFS=',' read -r -a explicitly_selected_boosters <<< "$OPTARG"
            selection_type=-1

            echo -e "${YELLOW}== Will use all the booster(s) except the following: '${BLUE}$OPTARG${YELLOW}' ==${NC}"
            echo
        ;;
        \?)
            error "Invalid option: -$OPTARG" 1>&2
        ;;
    esac
done
shift $((OPTIND - 1))

subcommand=$1
cmd=""
declare preCmd
declare postCmd
case "$subcommand" in
    release)
        if [[ "$COMMIT" == off ]]; then
            log_failed "The dry-run option is not supported for the release command"
            exit 1
        fi
        cmd="release"
        branches=( "master" )
        echo -e "${YELLOW}== Release only works on the '${BLUE}master${YELLOW}' branch, disregarding any branch set by -b option ==${NC}"
        echo
    ;;
    catalog)
        preCmd="prepare_catalog"
        shift
        cmd="catalog ${1}"
        postCmd="open_catalog_pr ${1}"
        branches=( "master" )
        echo -e "${YELLOW}== Catalog only works on the '${BLUE}master${YELLOW}' branch, disregarding any branch set by -b option ==${NC}"
        echo
    ;;
    create_branch)
        CREATE_BRANCH='on'
        cmd="create_branch"

        # don't allow creating any of the protected branches
        for br in "${branches[@]}"
        do
          if element_in "${br}" "${default_branches[@]}"; then
              error "create_branch must be used when with branch(es) specified via -b. The specified branches cannot contain any of the protected branches" 1>&2
          fi
        done
    ;;
    delete_branch)
        cmd="delete_branch"

        # don't allow deleting any of the protected branches
        for br in "${branches[@]}"
        do
          if element_in "${br}" "${default_branches[@]}"; then
              error "delete_branch must be used when with branch(es) specified via -b. The specified branches cannot contain any of the protected branches" 1>&2
          fi
        done
    ;;
    change_version)
        # Needed in order to "reset" the options processing for the subcommand
        OPTIND=2
        # Process options of subcommand
        while getopts ":hpv:" opt2; do
            case ${opt2} in
                h)
                    show_change_version_help
                    exit 0
                ;;
                v)
                    version=$OPTARG
                ;;
                \?)
                    error "Invalid change_version option: -$OPTARG" "show_change_version_help" 1>&2
                ;;
                :)
                    error "Invalid change_version option: -$OPTARG requires an argument" "show_change_version_help" 1>&2
                ;;
            esac
        done
        shift $((OPTIND - 1))

        cmd="change_version ${version:-compute}"
    ;;
    script)
        shift
        if [ -n "$1" ]; then
            cmd="source $1"
        else
            error "Must provide a script to execute" 1>&2
        fi
    ;;
    revert)
        IGNORE_LOCAL_CHANGES='on'
        cmd="revert"
    ;;
    run_integration_tests)
        shift
        cmd="run_integration_tests ${1}"
    ;;
    run_smoke_tests)
        cmd="run_smoke_tests"
    ;;
    set_maven_property)
        run_verification=false

        # Needed in order to "reset" the options processing for the subcommand
        OPTIND=2
        # Process options of subcommand
        while getopts ":hv" opt2; do
            case ${opt2} in
                h)
                    show_set_maven_property_help
                    exit 0
                ;;
                v)
                    run_verification=true
                ;;
                \?)
                    error "Invalid set_maven_property option: -$OPTARG" "show_set_maven_property_help" 1>&2
                ;;
            esac
        done
        shift $((OPTIND - 1))
        if [ -n "$2" ]; then
            cmd="set_maven_property $1 $2 ${run_verification}"
        else
            error "Must provide a property name and a property value" 1>&2
        fi
    ;;
    cmd)
        # Needed in order to "reset" the options processing for the subcommand
        OPTIND=2
        # Process options of subcommand
        while getopts ":hp:" opt2; do
            case ${opt2} in
                h)
                    show_cmd_help
                    exit 0
                ;;
                p)
                    message=$OPTARG
                ;;
                \?)
                    error "Invalid cmd option: -$OPTARG" "show_cmd_help" 1>&2
                ;;
                :)
                    error "Invalid cmd option: -$OPTARG requires an argument" "show_cmd_help" 1>&2
                ;;
            esac
        done
        shift $((OPTIND - 1))
        if [ -n "$1" ]; then
            cmd="run_cmd $1 ---- ${message}"
        else
            error "Must provide a command to execute" 1>&2
        fi
    ;;
    fn)
        shift
        if [ -n "$1" ]; then
            cmd="$1" # record command name
            shift # remove command name from args
            cmd="${cmd} $@" # append args
            cmd=$(trim ${cmd})
        else
            error "Must provide a function to execute" 1>&2
        fi
    ;;
    *)
        error "Unknown command: '${subcommand}'" 1>&2
    ;;
esac

# The following populates the array with entries like:
# spring-boot-cache-booster,git@github.com:snowdrop/spring-boot-cache-booster.git
# spring-boot-circuit-breaker-booster,git@github.com:snowdrop/spring-boot-circuit-breaker-booster.git
all_boosters_from_github=($(curl -s https://api.github.com/search/repositories\?q\=${github_query} | jq -j '.items[] | .name, ",", .ssh_url, "\n"' | sort))
if [ ${#all_boosters_from_github[@]} == 0 ]; then
    echo -e "${RED}No projects matching the query were found on GitHub${NC}"
    exit 1
fi
pushd ${BOOSTERS_DIR} > /dev/null

if [ -n "${preCmd}" ]; then
    simple_log "Executing pre-boosters processing command '${YELLOW}${preCmd}${BLUE}'"
    if ! ${preCmd}; then
        simple_log "Couldn't run ${YELLOW}${preCmd}"
        echo
    fi
fi


for booster_line in ${all_boosters_from_github[@]}
do
    IFS=',' read -r -a booster_parts <<< "${booster_line}"
    export BOOSTER=${booster_parts[0]}
    BOOSTER_GIT_URL=${booster_parts[1]}
    booster_simple_name=$(simple_name)
    # We process the boosters when one of the following conditions is true
    # 1) the user made no explicit booster selections (therefore all boosters are processed)
    # 2) the user explicitly included the booster using it's simple name (the part without 'spring-boot-' and '-booster')
    # 3) the user did not include the simple booster name in the explicitly excluded boosters
    should_process=true
    if ((selection_type > 0)) && ! element_in "${booster_simple_name}" "${explicitly_selected_boosters[@]}"; then
      should_process=false
    elif ((selection_type < 0)) && element_in "${booster_simple_name}" "${explicitly_selected_boosters[@]}"; then
      should_process=false
    fi

    if [ "$should_process" = true ] ; then
      echo -e "${BLUE}> ${YELLOW}${BOOSTER}${BLUE}${NC}"

      if [[ "$PERFORM_BOOSTER_LOCAL_SETUP" == on ]]; then
        setup_booster_locally ${BOOSTER} ${BOOSTER_GIT_URL}
      fi

      pushd ${BOOSTER} > /dev/null

      if [ ! -d .git ]; then
          msg="Not under git control"
          echo -e "${MAGENTA}${msg}${MAGENTA}. Ignoring.${NC}"
          ignoredItem="${BOOSTER}:\"${msg}\""
          ignored+=( "${ignoredItem}" )
      else
          for BRANCH in "${branches[@]}"
          do
              export BRANCH
              bypassUpdate='off'
              # check if branch exists, otherwise skip booster
              if [ "$CREATE_BRANCH" != on ] && ! git show-ref --verify --quiet refs/heads/${BRANCH}; then
                  # check if a remote but not locally present branch exist and check it out if it does
                  if git ls-remote --heads "${remote}" "${BRANCH}" | grep "${BRANCH}" > /dev/null; then
                      git checkout -b "${BRANCH}" "${remote}"/"${BRANCH}"
                      bypassUpdate='on'
                  else
                      log_ignored "Branch does not exist"
                      continue
                  fi
              fi

              if [ "$bypassUpdate" == off ]; then
                  git fetch --tags -q "${remote}" > /dev/null

                  updateBranch=${BRANCH}
                  # when the command is create_branch, we need to checkout master in order to create the new branch
                  # in the case of delete_branch we need to checkout master in order to be able to delete the branch
                  # since we can't delete the branch that is currently checked out
                  if [ "$cmd" == "create_branch" ] || [ "$cmd" == "delete_branch" ]; then
                    updateBranch="master"
                  fi

                  if [ "$IGNORE_LOCAL_CHANGES" != on ]; then
                      # if booster has uncommitted changes, skip it
                      if [[ $(git status --porcelain) ]]; then
                          log_ignored "You have uncommitted changes, please stash these changes"
                          continue
                      fi

                      git checkout -q "${updateBranch}" > /dev/null && git rebase "${remote}"/"${updateBranch}" > /dev/null
                  else
                      git checkout -q "${updateBranch}" > /dev/null
                  fi
              fi


              # if we need to replace a multi-line match in the pom file of each booster, for example:
              # perl -pi -e 'undef $/; s/<properties>\s*<\/properties>/replacement/' pom.xml

              # if we need to execute sed on the result of find:
              # find . -name "application.yaml" -exec sed -i '' -e "s/provider: fabric8/provider: snowdrop/g" {} +

              log "Executing '${YELLOW}${cmd}${BLUE}'"
              # let the command fail without impacting the main loop, let the command decide on what to log / fail / ignore
              if ! ${cmd}; then
                  log "Done"
                  echo
                  continue
              fi

              log "Done"
              processedItem="${BRANCH}:${BOOSTER}"
              processed+=( "${processedItem}" )
              echo
          done
      fi

      echo -e "----------------------------------------------------------------------------------------\n"
      popd > /dev/null

    fi
done

if [ -n "${postCmd}" ]; then
    simple_log "Executing post-boosters processing command '${YELLOW}${postCmd}${BLUE}'"
    if ! ${postCmd}; then
        simple_log "Couldn't run ${YELLOW}${postCmd}"
        echo
    fi
fi


popd > /dev/null

if [ ${#processed[@]} != 0 ]; then
    echo -e "${BLUE}${#processed[@]} booster/branch combinations were processed:${YELLOW}"
    printf '\t%s\n' "${processed[@]}"
fi

if [ ${#failed[@]} != 0 ]; then
    echo -e "${BLUE}${#failed[@]} booster/branch combinations failed:${RED}"
    printf '\t%s\n' "${failed[@]}"
fi

if [ ${#ignored[@]} != 0 ]; then
    echo -e "${BLUE}${#ignored[@]} booster/branch combinations  were skipped:${MAGENTA}"
    printf '\t%s\n' "${ignored[@]}"
fi
