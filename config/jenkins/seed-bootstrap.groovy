freeStyleJob('SeedJob') {
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
