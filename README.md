# rafale
CA UIM - High performance rafale mode probe

# Configuration overview

```xml
<setup>
    loglevel = 1 <!-- classical nimsoft loglevel -->
    logsize = 1024 <!-- logsize in KB -->
    debug = 0 <!-- advanced debug mode -->
    post_subject = alarm2 <!-- subject where pds are posted when enrichment is done -->
    pool_threads = 3 <!-- number of threads in the pool -->
    storm_protection = 1000 <!-- storm protection -->
    <!-- queue_attach = queueName -->
    <!-- login = administrator -->
    <!-- password = password -->
</setup>
<rafale-rules>
    <!-- Break on the first rafale rule matched, set to 'yes' by default -->
    exclusive_rafale = yes
    <100>
        <!-- Alarm field to match -->
        match_alarm_field = udata.message
        <!-- regexp to match on the field (like alarm_enrichment) -->
        match_alarm_regexp = .*Your\salarm\smessage\shere.* 
        <!-- 
            Trigger an alarm if we have 2 alarm in less than 60 seconds with a severity of 5. 
            Put no will reverse the behavior.
            Default value = yes
        -->
        trigger_alarm_on_match = yes 
        <!-- Number of alarm rows we want to have the alarm before triggering a new one! -->
        required_alarm_rowcount = 2
        <!-- The interval where we want to check alarm rowcount (in second) -->
        required_alarm_interval = 60
        <!-- Alarm severity, if no value is entered it will leave no severity check -->
        required_alarm_severity = 5
    </100>
</rafale-rules>
<database>
    provider = MSSQL
    connectionString = 
</database>
```