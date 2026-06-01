#!/usr/bin/env bash

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

SPARK_VERSION="${SPARK_VERSION:-}"
MAVEN_PROFILES="${MAVEN_PROFILES:--Pyarn -Pkubernetes -Phadoop-3 -Phive -Phive-thriftserver}"
MAVEN_EXTRA_ARGS="${MAVEN_EXTRA_ARGS:-}"
DIST_NAME="${DIST_NAME:-hadoop3}"
IMAGE_TARGET="${IMAGE_TARGET:-rmc}"
IMAGE_NAME="${IMAGE_NAME:-kyuubi-spark}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-rmc-registry-qa.webex.com/wap-dataprocessor/${IMAGE_NAME}}"
ECR_REGISTRY="${ECR_REGISTRY:-527856644868.dkr.ecr.us-east-2.amazonaws.com}"
ECR_REPOSITORY="${ECR_REPOSITORY:-webex-wap/wap-dataprocessor/${IMAGE_NAME}}"
GIT_SHORT_SHA="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
GIT_SHORT_SHA="${GIT_SHORT_SHA:0:4}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
BUILD_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
IMAGE_TAG="${IMAGE_TAG:-}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"
MULTI_ARCH="${MULTI_ARCH:-false}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
DOCKER_LOGIN="${DOCKER_LOGIN:-true}"
RMC_REGISTRY="${RMC_REGISTRY:-rmc-registry-qa.webex.com}"
ART_REGISTRY="${ART_REGISTRY:-artifactory.devhub-cloud.cisco.com}"
BASE_IMAGE="${BASE_IMAGE:-eclipse-temurin:17.0.19_10-jre-jammy}"
DOCKERFILE="${DOCKERFILE:-}"
SPARK_UID="${SPARK_UID:-}"
SPARK_EXTRA_JAR_URLS_FILE="${SPARK_EXTRA_JAR_URLS_FILE:-.github/image-jars/spark-extra-jars.txt}"
SPARK_EXTRA_JAR_URLS="${SPARK_EXTRA_JAR_URLS:-${EXTRA_JAR_URLS:-}}"
ANCHORE_SCAN="${ANCHORE_SCAN:-false}"
ANCHORE_FAIL_ON_POLICY_FAIL="${ANCHORE_FAIL_ON_POLICY_FAIL:-false}"
ANCHORE_HOME="${ANCHORE_HOME:-${RUNNER_TEMP:-/tmp}/anchore}"
ANCHORE_TMPDIR="${ANCHORE_TMPDIR:-${ANCHORE_HOME}/tmp}"
SYFT_BIN="${SYFT_BIN:-${ANCHORE_HOME}/bin/syft}"
ANCHORECTL_BIN="${ANCHORECTL_BIN:-${ANCHORE_HOME}/bin/anchorectl}"

function error {
  echo "ERROR: $*" >&2
  exit 1
}

function require_command {
  command -v "$1" >/dev/null 2>&1 || error "Cannot find required command: $1"
}

function require_env {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    error "Environment variable ${name} is required"
  fi
}

function is_true {
  [[ "$1" == "true" || "$1" == "1" || "$1" == "yes" ]]
}

function resolve_path {
  local path="$1"
  if [[ -n "${path}" && "${path}" != /* ]]; then
    path="${REPO_ROOT}/${path}"
  fi
  echo "${path}"
}

function resolve_executable {
  local configured_path="$1"
  local command_name="$2"

  if [[ -n "${configured_path}" ]]; then
    configured_path="$(resolve_path "${configured_path}")"
    if [[ -x "${configured_path}" ]]; then
      echo "${configured_path}"
      return
    fi
  fi

  if command -v "${command_name}" >/dev/null 2>&1; then
    command -v "${command_name}"
    return
  fi

  error "Cannot find executable ${command_name}. Put it on PATH or configure its *_BIN path"
}

function strip_image_name {
  local repository="$1"
  repository="${repository%/}"
  repository="${repository%/${IMAGE_NAME}}"
  echo "${repository}"
}

function image_repository_for_target {
  local target="$1"
  case "${target}" in
    rmc)
      strip_image_name "${IMAGE_REPOSITORY}"
      ;;
    ecr)
      strip_image_name "${ECR_REGISTRY}/${ECR_REPOSITORY}"
      ;;
    *)
      error "Unsupported image target=${target}. Expected one of: rmc, ecr"
      ;;
  esac
}

function resolve_image_repositories {
  IMAGE_REPOSITORIES=()
  IMAGE_REFS=()

  case "${IMAGE_TARGET}" in
    rmc)
      IMAGE_REPOSITORIES+=("$(image_repository_for_target rmc)")
      ;;
    ecr)
      IMAGE_REPOSITORIES+=("$(image_repository_for_target ecr)")
      ;;
    both)
      IMAGE_REPOSITORIES+=("$(image_repository_for_target rmc)")
      IMAGE_REPOSITORIES+=("$(image_repository_for_target ecr)")
      ;;
    *)
      error "Unsupported IMAGE_TARGET=${IMAGE_TARGET}. Expected one of: rmc, ecr, both"
      ;;
  esac

  IMAGE_REPOSITORY="${IMAGE_REPOSITORIES[0]}"
  export IMAGE_REPOSITORY
  echo "image_target=${IMAGE_TARGET}"
  local repository
  for repository in "${IMAGE_REPOSITORIES[@]}"; do
    IMAGE_REFS+=("${repository}/${IMAGE_NAME}:${IMAGE_TAG}")
    echo "image=${repository}/${IMAGE_NAME}:${IMAGE_TAG}"
  done
}

function evaluate_maven_property {
  local property="$1"
  ./build/mvn help:evaluate \
    -Dexpression="${property}" \
    ${MAVEN_PROFILES} \
    -q -DforceStdout
}

function resolve_spark_version {
  echo "Resolving Spark project version with ${MAVEN_PROFILES}"

  local project_version
  project_version="$(evaluate_maven_property project.version)"
  echo "project.version=${project_version}"

  local scala_binary_version
  scala_binary_version="$(evaluate_maven_property scala.binary.version)"
  echo "scala.binary.version=${scala_binary_version}"
  if [[ "${scala_binary_version}" != "2.13" ]]; then
    error "Expected scala.binary.version=2.13, got ${scala_binary_version}"
  fi

  if [[ ! "${project_version}" =~ ^4\.1\. ]]; then
    error "Expected Spark 4.1.x project.version, got ${project_version}"
  fi

  if [[ -z "${SPARK_VERSION}" ]]; then
    SPARK_VERSION="${project_version}"
  else
    echo "Using SPARK_VERSION=${SPARK_VERSION} for the generated image tag"
    if [[ "${SPARK_VERSION}" != "${project_version}" ]]; then
      echo "SPARK_VERSION differs from project.version=${project_version}; the build still uses the checked-out source"
    fi
  fi
  export SPARK_VERSION

  if [[ -z "${IMAGE_TAG}" ]]; then
    local image_tag_version="${SPARK_VERSION%-SNAPSHOT}"
    IMAGE_TAG="${image_tag_version}-r${BUILD_NUMBER}-${GIT_SHORT_SHA}"
  fi
  export IMAGE_TAG
  echo "image_tag=${IMAGE_TAG}"
}

function verify_multi_arch_options {
  if ! is_true "${MULTI_ARCH}"; then
    return
  fi

  if ! is_true "${PUSH_IMAGE}"; then
    error "MULTI_ARCH=true requires PUSH_IMAGE=true because docker buildx pushes the multi-arch manifest during build"
  fi

  if [[ -z "${PLATFORMS}" ]]; then
    error "PLATFORMS must not be empty when MULTI_ARCH=true"
  fi

  docker buildx version >/dev/null 2>&1 || error "docker buildx is required for multi-arch image builds"

  echo "multi_arch=true"
  echo "platforms=${PLATFORMS}"
}

function setup_multi_arch_builder {
  if ! is_true "${MULTI_ARCH}"; then
    return
  fi

  local builder_name="${BUILDX_BUILDER_NAME:-kyuubi-spark-multiarch-builder}"
  if docker buildx inspect "${builder_name}" >/dev/null 2>&1; then
    docker buildx use "${builder_name}"
  else
    docker buildx create --name "${builder_name}" --driver docker-container --use
  fi
  docker buildx inspect --bootstrap
}

function build_distribution {
  echo "Building Spark distribution for ${SPARK_VERSION}"
  ./dev/make-distribution.sh \
    --name "${DIST_NAME}" \
    ${MAVEN_PROFILES} \
    ${MAVEN_EXTRA_ARGS}
}

function jar_url_lines {
  local label="$1"
  local inline_urls="$2"
  local urls_file="$3"

  if [[ -n "${inline_urls}" ]]; then
    echo "Using ${label} extra jar URLs from workflow input" >&2
    printf '%s' "${inline_urls}" | tr ',;' '\n'
    return
  fi

  if [[ -z "${urls_file}" ]]; then
    return
  fi

  urls_file="$(resolve_path "${urls_file}")"
  if [[ ! -f "${urls_file}" ]]; then
    echo "No ${label} extra jar list file found: ${urls_file}" >&2
    return
  fi

  echo "Using ${label} extra jar list file: ${urls_file}" >&2
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "${line}" | xargs)"
    if [[ -n "${line}" ]]; then
      printf '%s\n' "${line}"
    fi
  done < "${urls_file}"
}

function download_jars_to_dir {
  local label="$1"
  local target_dir="$2"
  local jar_urls="$3"
  local jar_urls_file="$4"

  if [[ -z "${jar_urls}" && -z "${jar_urls_file}" ]]; then
    echo "No ${label} extra jars configured"
    return
  fi

  echo "Downloading ${label} extra jars into ${target_dir}"
  mkdir -p "${target_dir}"
  local downloaded_jars=()

  while IFS= read -r raw_url; do
    local jar_url
    jar_url="$(echo "${raw_url}" | xargs)"
    if [[ -z "${jar_url}" ]]; then
      continue
    fi

    local jar_name
    jar_name="$(basename "${jar_url%%\?*}")"
    echo "Downloading ${jar_name}"
    curl -fL --retry 3 --retry-delay 5 -o "${target_dir}/${jar_name}" "${jar_url}"
    downloaded_jars+=("${jar_name}")
  done < <(jar_url_lines "${label}" "${jar_urls}" "${jar_urls_file}")

  if [[ "${#downloaded_jars[@]}" -eq 0 ]]; then
    echo "No ${label} extra jar URLs parsed"
    return
  fi

  echo "Downloaded ${label} extra jars:"
  local jar_name
  for jar_name in "${downloaded_jars[@]}"; do
    if [[ ! -s "${target_dir}/${jar_name}" ]]; then
      error "Missing or empty ${label} extra jar: ${target_dir}/${jar_name}"
    fi
    ls -lh "${target_dir}/${jar_name}"
  done
}

function download_extra_jars {
  download_jars_to_dir "spark" "dist/jars" "${SPARK_EXTRA_JAR_URLS}" "${SPARK_EXTRA_JAR_URLS_FILE}"
}

function docker_login_if_needed {
  if ! is_true "${DOCKER_LOGIN}"; then
    echo "Skipping docker login"
    return
  fi

  require_env ART_USERNAME
  require_env ART_PASSWORD

  case "${IMAGE_TARGET}" in
    rmc|both)
      require_env RMC_USERNAME
      require_env RMC_PASSWORD

      echo "Logging in to ${RMC_REGISTRY}"
      echo "${RMC_PASSWORD}" | docker login --username="${RMC_USERNAME}" --password-stdin "${RMC_REGISTRY}"
      ;;
    ecr)
      echo "Skipping ECR docker login; using existing runner/registry authentication"
      ;;
  esac

  if [[ "${IMAGE_TARGET}" == "both" ]]; then
    echo "Skipping ECR docker login; using existing runner/registry authentication"
  fi

  echo "Logging in to ${ART_REGISTRY}"
  echo "${ART_PASSWORD}" | docker login --username="${ART_USERNAME}" --password-stdin "${ART_REGISTRY}"
}

function parse_base_image {
  if [[ -z "${BASE_IMAGE}" ]]; then
    return
  fi

  if [[ "${BASE_IMAGE##*/}" == *:* ]]; then
    JAVA_IMAGE_NAME="${BASE_IMAGE%:*}"
    JAVA_IMAGE_TAG="${BASE_IMAGE##*:}"
  else
    JAVA_IMAGE_NAME="${BASE_IMAGE}"
    JAVA_IMAGE_TAG="latest"
  fi
}

function resolve_dockerfile {
  if [[ -n "${DOCKERFILE}" ]]; then
    DOCKERFILE="$(resolve_path "${DOCKERFILE}")"
  else
    DOCKERFILE="${REPO_ROOT}/dist/kubernetes/dockerfiles/spark/Dockerfile"
  fi

  if [[ ! -f "${DOCKERFILE}" ]]; then
    error "Cannot find Dockerfile: ${DOCKERFILE}"
  fi
  echo "dockerfile=${DOCKERFILE}"
}

function build_args {
  parse_base_image

  if [[ -n "${JAVA_IMAGE_NAME:-}" ]]; then
    printf '%s\n' "--build-arg" "java_image_name=${JAVA_IMAGE_NAME}"
  fi
  if [[ -n "${JAVA_IMAGE_TAG:-}" ]]; then
    printf '%s\n' "--build-arg" "java_image_tag=${JAVA_IMAGE_TAG}"
  fi
  if [[ -n "${SPARK_UID}" ]]; then
    printf '%s\n' "--build-arg" "spark_uid=${SPARK_UID}"
  fi
}

function verify_distribution_for_image {
  if [[ ! -d "dist/kubernetes/dockerfiles" ]]; then
    error "Cannot find dist/kubernetes/dockerfiles. Build the distribution with -Pkubernetes."
  fi

  local total_jars
  total_jars="$(find dist/jars -maxdepth 1 -type f -name 'spark-*' | wc -l | xargs)"
  if [[ "${total_jars}" -eq 0 ]]; then
    error "Cannot find Spark JARs under dist/jars"
  fi
}

function build_image {
  resolve_dockerfile
  verify_distribution_for_image

  local docker_build_args=()
  while IFS= read -r arg; do
    docker_build_args+=("${arg}")
  done < <(build_args)

  if is_true "${MULTI_ARCH}"; then
    local tag_args=()
    local image_ref
    for image_ref in "${IMAGE_REFS[@]}"; do
      tag_args+=("-t" "${image_ref}")
    done

    echo "Building and pushing multi-arch image for ${PLATFORMS}"
    (
      cd dist
      docker buildx build \
        --platform "${PLATFORMS}" \
        --provenance=false \
        --push \
        "${docker_build_args[@]}" \
        "${tag_args[@]}" \
        -f "${DOCKERFILE}" \
        .
    )
    return
  fi

  local primary_image="${IMAGE_REFS[0]}"
  echo "Building image ${primary_image}"
  (
    cd dist
    docker build \
      "${docker_build_args[@]}" \
      -t "${primary_image}" \
      -f "${DOCKERFILE}" \
      .
  )

  local image_ref
  for image_ref in "${IMAGE_REFS[@]:1}"; do
    echo "Tagging image ${image_ref}"
    docker tag "${primary_image}" "${image_ref}"
  done
}

function push_image_if_needed {
  if is_true "${MULTI_ARCH}"; then
    echo "Skipping separate docker push; docker buildx already pushed the multi-arch image"
    return
  fi

  if ! is_true "${PUSH_IMAGE}"; then
    echo "Skipping image push. Set PUSH_IMAGE=true to push ${IMAGE_REFS[0]}"
    return
  fi

  local image_ref
  for image_ref in "${IMAGE_REFS[@]}"; do
    echo "Pushing image ${image_ref}"
    docker push "${image_ref}"
  done
}

function scan_anchore_image {
  local image_ref="$1"
  local syft_bin
  local anchorectl_bin
  local check_output
  local policy_evaluation_status

  syft_bin="$(resolve_executable "${SYFT_BIN}" syft)"
  anchorectl_bin="$(resolve_executable "${ANCHORECTL_BIN}" anchorectl)"
  mkdir -p "${ANCHORE_TMPDIR}"

  echo "Running Anchore scan for ${image_ref}"
  TMPDIR="${ANCHORE_TMPDIR}" "${syft_bin}" -o json "${image_ref}" | \
    TMPDIR="${ANCHORE_TMPDIR}" "${anchorectl_bin}" image add "${image_ref}" --wait --from -

  check_output="$(TMPDIR="${ANCHORE_TMPDIR}" "${anchorectl_bin}" image check "${image_ref}")"
  echo "${check_output}"

  policy_evaluation_status="$(printf '%s\n' "${check_output}" | sed -n 's/^Evaluation: //p' | head -n 1 | tr -d '\r')"
  if [[ -z "${policy_evaluation_status}" ]]; then
    error "Cannot parse Anchore policy Evaluation for ${image_ref}"
  fi

  echo "Anchore policy evaluation for ${image_ref}: ${policy_evaluation_status}"
  if [[ "${policy_evaluation_status}" == "fail" ]]; then
    if is_true "${ANCHORE_FAIL_ON_POLICY_FAIL}"; then
      error "Build failed because image failed Anchore scan: ${image_ref}"
    fi
    echo "Anchore policy failed, but ANCHORE_FAIL_ON_POLICY_FAIL=false"
  fi
}

function scan_anchore_images_if_needed {
  if ! is_true "${ANCHORE_SCAN}"; then
    echo "Skipping Anchore image scan"
    return
  fi

  require_env ANCHORECTL_ACCOUNT
  require_env ANCHORECTL_URL
  require_env ANCHORECTL_USERNAME
  require_env ANCHORECTL_PASSWORD

  local image_ref
  for image_ref in "${IMAGE_REFS[@]}"; do
    scan_anchore_image "${image_ref}"
  done
}

require_command curl
require_command docker

resolve_spark_version
resolve_image_repositories
verify_multi_arch_options
build_distribution
download_extra_jars
docker_login_if_needed
setup_multi_arch_builder
build_image
push_image_if_needed
scan_anchore_images_if_needed

echo "Done:"
for image_ref in "${IMAGE_REFS[@]}"; do
  echo "  ${image_ref}"
done
