@Library('xmos_jenkins_shared_library@develop') _
// need to move this on when JSL is released
// @Library('xmos_jenkins_shared_library@v0.33.0') _
getApproval()
pipeline {
    agent none

    environment {
        REPO = 'lib_mic_array'
        PIP_VERSION = "24.0"
        PYTHON_VERSION = "3.11"
        XMOSDOC_VERSION = "v6.0.0"          
    }
    options {
        disableConcurrentBuilds()
        skipDefaultCheckout()
        timestamps()
        // on develop discard builds after a certain number else keep forever
        buildDiscarder(logRotator(
            numToKeepStr:         env.BRANCH_NAME ==~ /develop/ ? '25' : '',
            artifactNumToKeepStr: env.BRANCH_NAME ==~ /develop/ ? '25' : ''
        ))
    }
    parameters {
        string(
            name: 'TOOLS_VERSION',
            defaultValue: '15.3.0',
            description: 'The XTC tools version'
        )
    }
    stages {
        stage('Build and Docs') {
            parallel {
                stage('Documentation') {
                    agent {
                        label "docker"
                    }
                    steps {
                        dir("${REPO}") {
                            warnError("Docs") {
                                sh "docker pull ghcr.io/xmos/xmosdoc:$XMOSDOC_VERSION"
                                sh """docker run -u "\$(id -u):\$(id -g)" \
                                      --rm \
                                      -v \$(pwd):/build \
                                      ghcr.io/xmos/xmosdoc:$XMOSDOC_VERSION -v html latex"""

                                // Zip and archive doc files
                                zip dir: "doc/_build/html", zipFile: "${REPO}_docs_html.zip"
                                archiveArtifacts artifacts: "${REPO}_docs_html.zip"
                                archiveArtifacts artifacts: "doc/_build/pdf/${REPO}*.pdf"
                            }
                        }
                    }
                    post {
                        cleanup {
                            xcoreCleanSandbox()
                        }
                    }
                }
                stage('XCommon build') {
                    agent {
                        label "x86_64 && linux"
                    }
                    steps {
                        dir("${REPO}") {
                            checkout scm
                            dir("tests") {
                                withTools(params.TOOLS_VERSION) {
                                    sh 'cmake -B build -G "Unix Makefiles"'
                                    dir("xcommon_build") {
                                        sh "xmake all -j 16"
                                    }
                                }
                            }
                            // archiveArtifacts artifacts: "doc/_build/**", allowEmptyArchive: true
                        }
                    }
                    post {
                        cleanup {
                            xcoreCleanSandbox()
                        }
                    }
                }
                stage('Custom CMake build') {
                    agent {
                        label "x86_64 && linux" 
                    }
                    steps {
                        dir("${REPO}") {
                            checkout scm
                            sh 'git submodule update --init --recursive --depth 1'
                            sh "wget https://raw.githubusercontent.com/xmos/xmos_cmake_toolchain/main/xs3a.cmake"
                            sh "wget https://raw.githubusercontent.com/xmos/xmos_cmake_toolchain/main/xc_override.cmake"
                            withTools(params.TOOLS_VERSION) {
                                sh "cmake -B build.xcore -DDEV_LIB_MIC_ARRAY=1 -DCMAKE_TOOLCHAIN_FILE=./xs3a.cmake"
                                sh "pushd build.xcore"
                                sh "make all -j 16"
                            }
                        }
                    }
                    post {
                        cleanup {
                            xcoreCleanSandbox()
                        }
                    }
                }
                stage('XCCM build and basic tests') {
                    agent {
                        label 'x86_64 && linux'
                    }
                    stages {
                        stage("XCCM Build") {
                            // Clone and install build dependencies
                            steps {
                                // Clone infrastructure repos
                                sh "git clone --branch v1.6.0 git@github.com:xmos/infr_apps"
                                sh "git clone --branch v1.3.0 git@github.com:xmos/infr_scripts_py"
                                // clone
                                dir("$REPO/examples") {
                                    checkout scm
                                    installPipfile(false)
                                    withVenv {
                                        withTools(params.TOOLS_VERSION) {
                                            sh 'cmake -B build -G "Unix Makefiles"'
                                            sh 'xmake -j 16 -C build'
                                        }
                                    }
                                }
                            }
                        }
                        stage("Lib checks") {
                            steps {
                                runLibraryChecks("${WORKSPACE}/${REPO}", "v2.0.0")
                            }
                        }
                    }
                    post {
                        cleanup {
                            xcoreCleanSandbox()
                        }
                    }
                }
            }
        }
        stage('HW tests') {
            when {
                expression { !env.GH_LABEL_DOC_ONLY.toBoolean() }
            }
            agent {
                label 'xvf3800' // We have plenty of these (6) and they have a single XTAG connected
            }
            stages {
                stage("Setup") {
                    steps {
                        dir("$REPO") {
                            println "RUNNING ON"
                            println env.NODE_NAME
                            checkout scm
                            sh "git submodule update --init --recursive"
                            withTools(params.TOOLS_VERSION) {
                                installDependencies()
                            }
                        }
                    }
                }
                stage("Build firmware") {
                    steps {
                        withTools(params.TOOLS_VERSION) {
                            dir("$REPO"){
                                sh ". .github/scripts/build_test_apps.sh"
                            }
                        }
                    }
                }
                stage('Run tests') {
                    steps {
                        dir("${REPO}") {
                            withTools(params.TOOLS_VERSION) {
                                withVenv {
                                    // Use xtagctl to reset the relevent adapters first, if attached, to be safe.
                                    // sh "xtagctl reset_all XVF3800_INT XVF3600_USB"
                                    // sh ". .github/scripts/run_test_apps.sh"
                                    // # Unit tests
                                    // xrun --xscope tests/unit/tests-unit.xe

                                    // # Signal/Decimator tests
                                    // pytest ../tests/signal/TwoStageDecimator/ -vv

                                    // # Filter design tests
                                    // pytest ../tests/signal/FilterDesign/ -vv
                                }
                            }
                        }
                        dir("${REPO}/..") {
                            // archiveArtifacts artifacts: "src/BeClearMemory.S", fingerprint: true
                        }
                    }
                }
            }
            post {
                cleanup {
                    xcoreCleanSandbox()
                    cleanWs()
                }
            }
        }
    }
}
