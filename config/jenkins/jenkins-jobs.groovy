def repoUrl = System.getenv('GITHUB_REPO_URL') ?: 'https://github.com/your-org/devops-setup.git'

// ─── FOLDER STRUCTURE ────────────────────────────────────────────────────────
folder('admin-tasks') {
    description('Admin tasks for the DevOps platform')
}
// folder('admin-tasks/Seed-Job') {
//     description('Admin tasks for the seed job')
// }
folder('admin-tasks/Agent-Test') {
    description('Admin tasks for testing the agents defined in the DevOps platform')
}
folder('admin-tasks/Connectivity-Test') {
    description('Admin tasks for testing the connectivity of the DevOps platform')
}

// ─── SEED JOB ────────────────────────────────────────────────────────────────
// This job re-scans this exact file to update all other jobs.
job('seed-job') {
    description('Re-generates all Jenkins jobs from the Groovy DSL script.')
    label('built-in') 
    steps {
        shell('cp /var/jenkins_config/jenkins_jobs.groovy jenkins_jobs.groovy')
        dsl {
            targets('jenkins_jobs.groovy')
            removeAction('DELETE')
            removeViewAction('DELETE')
            lookupStrategy('SEED_JOB')
        }
    }
}

// ─── CORE SETUP ─────────────────────────────────────────────────────────────
pipelineJob('admin-tasks/main-setup') {
    description('Main CI/CD Pipeline for DevOps Setup')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile')
        }
    }
}

// ─── AGENT TESTS ───────────────────────────────────────────────────────────
pipelineJob('admin-tasks/Agent-Test/test-agents') {
    description('Tests the dynamic Kubernetes build agents (Maven, Node.js, .NET, Python).')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.test-agents')
        }
    }
}

// ─── CONNECTIVITY TESTS ─────────────────────────────────────────────────────

pipelineJob('admin-tasks/Connectivity-Test/test-connectivity-python') {
    description('Tests external connectivity (GitHub, PyPI) from the Jenkins Python agent.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.connectivity-test-python')
        }
    }
}

pipelineJob('admin-tasks/Connectivity-Test/test-connectivity-maven') {
    description('Tests external connectivity (Maven Central) from the Jenkins Maven agent.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.connectivity-test-maven')
        }
    }
}

pipelineJob('admin-tasks/Connectivity-Test/test-connectivity-nodejs') {
    description('Tests external connectivity (NPM Registry) from the Jenkins Node.js agent.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.connectivity-test-nodejs')
        }
    }
}

pipelineJob('admin-tasks/Connectivity-Test/test-connectivity-dotnet') {
    description('Tests external connectivity (NuGet) from the Jenkins .NET agent.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { 
                        url(repoUrl)
                        credentials('github-token')
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.connectivity-test-dotnet')
        }
    }
}
