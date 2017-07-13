use strict;
use warnings;
use lib "E:/Nimsoft/perllib";
use Data::Dumper;
use threads;
use Thread::Queue;
use threads::shared;
use Nimbus::API;
use Nimbus::PDS;
use Lib::rafale_rule;
use Perluim::API;
use Perluim::Addons::CFGManager;

# Global variables
my ($STR_Login,$STR_Password,$STR_NIMDomain,$BOOL_DEBUG,$STR_NBThreads,$BOOL_ExclusiveRafale,$INT_Logsize,$INT_StormProtection);
my ($STR_ReadSubject,$STR_PostSubject);
my %RafaleRules = ();
my %RulesSQLData = ();
my $HASH_Robot;
my $Probe_NAME  = "rafale";
my $Probe_VER   = "1.0";
my $Probe_CFG   = "rafale.cfg";
nimTimerStart($T_Heartbeat);
nimTimerStart($T_QOS);
$SIG{__DIE__} = \&scriptDieHandler;

my $Logger = uimLogger({
    file => "rafale.log",
    level => 3
});
$Logger->info("Probe $Probe_NAME initialized, version => $Probe_VER");

#
# scriptDieHandler
#
sub scriptDieHandler {
    my ($err) = @_; 
    print "$err";
    $Logger->fatal($err);
    exit(1);
}

#
# Init and configuration configuration
#
sub read_configuration {
    $Logger->nolevel("---------------------------------");
    $Logger->info("Read and parse configuration file!");
    my $CFGManager = Perluim::Addons::CFGManager->new($Probe_CFG,1);

    $CFGManager->setSection("setup");
    $BOOL_DEBUG              = $CFGManager->get("debug",0);
    $Logger->setLevel($CFGManager->get("loglevel",5));
    $Logger->trace($CFGManager) if $BOOL_DEBUG;

    $STR_Login               = $CFGManager->get("login","administrator");
    $STR_Password            = $CFGManager->get("password");
    $INT_Logsize             = $CFGManager->get("logsize",1024);
    $STR_ReadSubject         = $CFGManager->get("queue_attach",$Probe_NAME);
    $STR_PostSubject         = $CFGManager->get("post_subject");
    $STR_NBThreads           = $CFGManager->get("pool_threads",5);
    $INT_StormProtection     = $CFGManager->get('storm_protection',1000);
    $Logger->setSize($INT_Logsize);
    $Logger->truncate();

    @RafaleRules = ();
    $CFGManager->setSection("rafale-rules");
    $BOOL_ExclusiveRafale = $CFGManager->get("exclusive_rafale","no");

    my $Rules = $CFGManager->listSections("enrichment-rules");
    foreach my $RuleSection (@$Rules) {
        $CFGManager->setSection($RuleSection);
        my $match_alarm_field           = $CFGManager->get("match_alarm_field");
        my $match_alarm_regexp          = $CFGManager->get("match_alarm_regexp");
        my $required_alarm_count        = $CFGManager->get("required_alarm_rowcount",2);
        my $required_alarm_interval     = $CFGManager->get("required_alarm_interval",60);
        my $required_alarm_severity     = $CFGManager->get("required_alarm_severity");
        my $trigger_alarm_on_match      = $CFGManager->get("trigger_alarm_on_match","yes");
        if(defined $match_alarm_field && defined $match_alarm_regexp) {
            $RafaleRules{$RuleSection} = Lib::rafale_rule->new({
                name => $RuleSection,
                field => $match_alarm_field,
                regexp => qr/$match_alarm_regexp/,
                trigger_on_match => $trigger_alarm_on_match,
                count => $required_alarm_count,
                interval => $required_alarm_interval,
                severity => $required_alarm_severity
            });
        }
        else {
            $Logger->error("Please configure $RuleSection correctly!");
        }
    }

    $Lib::rafale_rule::Logger = $Logger;
    $Logger->nolevel("---------------------------------");
}
read_configuration();

# Login to Nimbus!
nimLogin("$STR_Login","$STR_Password") if defined $STR_Login && defined $STR_Password;

# Find Nimsoft Domain!
$Logger->info("Get nimsoft domain...");
{
    my ($RC,$STR_Domain) = nimGetVarStr(NIMV_HUBDOMAIN);
    scriptDieHandler("Failed to get domain!") if $RC != NIME_OK;
    $STR_NIMDomain = $STR_Domain;
}

$Logger->info("DOMAIN => $STR_NIMDomain");

# Get local robot info ! 
{
    my ($request,$response);
    $request = uimRequest({
        addr => "controller",
        callback => "get_info",
        retry => 3,
        timeout => 5
    });
    $response = $request->send(1);
    scriptDieHandler("Failed to get information for local robot") if not $response->rc(NIME_OK);
    $HASH_Robot = $response->hashData();
}

# Echo information about the robot where the script is started!
$Logger->info("HUBNAME => $HASH_Robot->{hubname}");
$Logger->info("ROBOTNAME => $HASH_Robot->{robotname}");
$Logger->info("VERSION => $HASH_Robot->{version}");
$Logger->nolevel("--------------------------------");

#
# Generate new alarm method
#
sub GenerateAlarm {
    my ($PDSHash) = @_;
    if(defined $PDSHash->{os_user1}) {
        $PDSHash->{user_tag_1} = $PDSHash->{os_user1};
        delete $PDSHash->{os_user1};
    }
    if(defined $PDSHash->{os_user2}) {
        $PDSHash->{user_tag_2} = $PDSHash->{os_user2};
        delete $PDSHash->{os_user2};
    }
    my $alarmID = nimId();
    my $PDS     = pdsFromHash($PDSHash);
    $PDS->string('subject',$STR_PostSubject);
    $PDS->string('nimid',$alarmID);
    my ($RC,$RES) = nimRequest("$HASH_Robot->{robotname}",48001,"post_raw",$PDS->data);
    $Logger->log(1,"Failed to send alarm => ".nimError2Txt($RC)) if $RC != NIME_OK;
}

#
# SQL handle thread!
#
my $SQLHandleThread = threads->create(sub {
    for (;;) {
        my $start = time;
        $Logger->log(1,"SQLHandle Interval executed...");
        # do work here ! 
        if ((my $remaining = 60000 - (time - $start)) > 0) {
            sleep $remaining;
        }
    }
});
$SQLHandleThread->detach();

#
# Threads pool
#
my $handleAlarm;
my $alarmQueue = Thread::Queue->new();
$handleAlarm = sub {
    $Logger->warn("Thread started!");
    while ( defined ( my $PDSHash = $alarmQueue->dequeue() ) ) {
        if(defined $PDSHash->{rafale}) {
            my $rafale_name = $PDSHash->{rafale};
            if(defined $RulesSQLData{$rafale_name}) {
                my $rowCount;
                {
                    lock($RulesSQLData{$rafale_name});
                    $rowCount = $RulesSQLData{$rafale_name}->{row_count};
                }
            }
            else {
                my %SQLRow : shared = (
                    row_count => 0,
                    updated => time(),
                    source => $PDSHash->{source},
                    origin => $PDSHash->{origin},
                    domain => $PDSHash->{domain}
                );
                $RulesSQLData{$rafale_name} = \%SQLRow;
            }
        }
        else {
            GenerateAlarm($PDSHash);
        }
    }
    $Logger->info("Thread finished!");
    return 1;
};

# Wait for group threads
my @thr = map {
    threads->create(\&$handleAlarm);
} 1..$STR_NBThreads;
$_->detach() for @thr;

#
# Register probe
# 
my $probe = uimProbe({
    name    => $Probe_NAME,
    version => $Probe_VER,
    timeout => 5000
});
$Logger->trace($probe);

# Register callbacks (String and Int are valid type for arguments)
$Logger->info("Register probe callbacks...");
$probe->registerCallback( "get_info" );

# Probe restarted
$probe->on( restart => sub {
    $Logger->log(0,"Probe restarted");
    read_configuration();
});

# Probe timeout
$probe->on( timeout => sub {
    eval {
        $Logger->truncate();
    };
    $Logger->error($@) if $@;
});

# Hubpost handle!
sub hubpost {
    my ($hMsg,$udata,$full) = @_;
    my $pending = $alarmQueue->pending() || 0; 
    if($pending >= $INT_StormProtection) {
        my $nimid = pdsGet_PCH($full,"nimid");
        $Logger->log(1,"Dropping alarm with nimid $nimid");
        nimSendReply($hMsg);
        return;
    }
    my $PDSHash = Nimbus::PDS->new($full)->asHash();
    my $rafaleMatch = 0;
    foreach my $rafaleName (keys %RafaleRules) {
        $rafaleMatch = $RafaleRules{$rafaleName}->processAlarm($PDSHash);
        if($rafaleMatch) {
            $PDSHash->{rafale} = $rafaleName;
            $alarmQueue->enqueue($PDSHash);
        }
        last if $rafaleMatch && $BOOL_ExclusiveRafale eq "yes";
    }
    $alarmQueue->enqueue($PDSHash) if !$rafaleMatch;
    nimSendReply($hMsg);
}

# Start probe!
$probe->attach($STR_ReadSubject);
$probe->start;
$Logger->nolevel("--------------------------------");

#
# get_info callback!
#
sub get_info {
    my ($hMsg) = @_;
    $Logger->log(0,"get_info callback triggered !");
    nimSendReply($hMsg,NIME_OK);
}
