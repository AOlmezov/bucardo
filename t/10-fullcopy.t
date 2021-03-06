#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Test fullcopy functionality

use 5.008003;
use strict;
use warnings;
use Data::Dumper;
use lib 't','.';
use DBD::Pg;
use Test::More;

use BucardoTesting;
my $bct = BucardoTesting->new() or BAIL_OUT "Creation of BucardoTesting object failed\n";
$location = 'fullcopy';

my $numtabletypes = keys %tabletype;
plan tests => 29 + ($numtabletypes * 13);

pass("*** Beginning 'fullcopy' tests");

use vars qw/ $dbhX $dbhA $dbhB $dbhC $dbhD $res $command $t %pkey $SQL %sth %sql/;

use vars qw/ $i $result /;

END {
    $bct->stop_bucardo($dbhX);
    $dbhX->disconnect();
    $dbhA->disconnect();
    $dbhB->disconnect();
    $dbhC->disconnect();
    $dbhD->disconnect();
}

## Get A, B, C, and D created, emptied out, and repopulated with sample data
$dbhA = $bct->repopulate_cluster('A');
$dbhB = $bct->repopulate_cluster('B');
$dbhC = $bct->repopulate_cluster('C');
$dbhD = $bct->repopulate_cluster('D');

## Create a bucardo database, and install Bucardo into it
$dbhX = $bct->setup_bucardo('A');

## Tell Bucardo about these databases

$t = 'Adding database from cluster A works';
my ($dbuser,$dbport,$dbhost) = $bct->add_db_args('A');
$command =
"bucardo_ctl add db bucardo_test name=A user=$dbuser port=$dbport host=$dbhost";
$res = $bct->ctl($command);
like ($res, qr/Added database "A"/, $t);

$t = 'Adding database from cluster B works';
($dbuser,$dbport,$dbhost) = $bct->add_db_args('B');
$command =
"bucardo_ctl add db bucardo_test name=B user=$dbuser port=$dbport host=$dbhost";
$res = $bct->ctl($command);
like ($res, qr/Added database "B"/, $t);

$t = 'Adding database from cluster C works';
($dbuser,$dbport,$dbhost) = $bct->add_db_args('C');
$command =
"bucardo_ctl add db bucardo_test name=C user=$dbuser port=$dbport host=$dbhost";
$res = $bct->ctl($command);
like ($res, qr/Added database "C"/, $t);

$t = 'Adding database from cluster D works';
($dbuser,$dbport,$dbhost) = $bct->add_db_args('D');
$command =
"bucardo_ctl add db bucardo_test name=D user=$dbuser port=$dbport host=$dbhost";
$res = $bct->ctl($command);
like ($res, qr/Added database "D"/, $t);

## Teach Bucardo about all tables, adding them to a new herd named "therd"
$t = q{Adding all tables on the master works};
$command =
"bucardo_ctl add tables all db=A herd=therd";
$res = $bct->ctl($command);
like ($res, qr/Creating herd: therd.*New tables added: \d/s, $t);

## Remove the 'droptest' table
$command =
"bucardo_ctl update herd therd remove droptest";
$res = $bct->ctl($command);
like ($res, qr/Removed from herd therd: public.droptest/, $t);

## Add all sequences, and add them to the newly created herd
$t = q{Adding all sequences on the master works};
$command =
"bucardo_ctl add sequences all db=A herd=therd";
$res = $bct->ctl($command);
like ($res, qr/New sequences added: \d/, $t);

## Add a new fullcopy sync that goes from A to B
$t = q{Adding a new fullcopy sync works};
$command =
"bucardo_ctl add sync testfullcopy type=fullcopy source=therd targetdb=B";
$res = $bct->ctl($command);
like ($res, qr/Added sync "testfullcopy"/, $t);

## Create a database group consisting of A and B
$t = q{Adding dbgroup 'slaves' works};
$command =
"bucardo_ctl add dbgroup slaves B C";
$res = $bct->ctl($command);
like ($res, qr/\QAdded database "B" to group "slaves"\E.*
              \QAdded database "C" to group "slaves"\E.*
              \QAdded database group "slaves"/xsm, $t);

## We want to know when the sync has finished
$dbhX->do(q{LISTEN "bucardo_syncdone_testfullcopy"});
$dbhX->commit();

## Time to startup Bucardo
$bct->restart_bucardo($dbhX);

## Now for the meat of the tests

## Get the statement handles ready for each table type
for my $table (sort keys %tabletype) {

    $pkey{$table} = $table =~ /test5/ ? q{"id space"} : 'id';

    ## INSERT
    for my $x (1..4) {
        $SQL = $table =~ /X/
            ? "INSERT INTO $table($pkey{$table}) VALUES (?)"
                : "INSERT INTO $table($pkey{$table},data1,inty) VALUES (?,'foo',$x)";
        $sth{insert}{$x}{$table}{A} = $dbhA->prepare($SQL);
        if ('BYTEA' eq $tabletype{$table}) {
            $sth{insert}{$x}{$table}{A}->bind_param(1, undef, {pg_type => PG_BYTEA});
        }
    }

    ## SELECT
    $sql{select}{$table} = "SELECT inty FROM $table ORDER BY $pkey{$table}";
    $table =~ /X/ and $sql{select}{$table} =~ s/inty/$pkey{$table}/;

    ## DELETE
    $SQL = "DELETE FROM $table";
    $sth{deleteall}{$table}{A} = $dbhA->prepare($SQL);

}

## Add one row per table type to A
for my $table (keys %tabletype) {
    my $type = $tabletype{$table};
    my $val1 = $val{$type}{1};
    $sth{insert}{1}{$table}{A}->execute($val1);
}

## Before the commit on A, B should be empty
for my $table (sort keys %tabletype) {
    my $type = $tabletype{$table};
    $t = qq{B has not received rows for table $table before A commits};
    $res = [];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}
$dbhA->commit();

## Have it vacuum afterwards
$t = q{Value of vacuum_after_copy can be changed};
$command =
'bucardo_ctl update sync testfullcopy vacuum_after_copy=1';
$res = $bct->ctl($command);
like ($res, qr{vacuum_after_copy}, $t);

## Reload the sync
$command =
"bucardo_ctl reload sync testfullcopy";
$res = $bct->ctl($command);

## Kick the sync and wait for it to finish
$bct->ctl('kick sync testfullcopy 0');

## Check the second database for the new rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Row with pkey of type $type gets copied to B};

    $res = [[1]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

## The droptest table should be populated for A, but not for B
for my $table (sort keys %tabletype) {

    $t = qq{Triggers and rules fired on A};
    $SQL = qq{SELECT type FROM droptest WHERE name = '$table' ORDER BY 1};

    $res = [['rule'],['trigger']];
    bc_deeply($res, $dbhA, $SQL, $t);

    $t = qq{Triggers and rules did not fire on B};
    $res = [];
    bc_deeply($res, $dbhB, $SQL, $t);
}

## Delete the rows from A, make sure deletion makes it to B
## Delete rows from A
for my $table (keys %tabletype) {
    $sth{deleteall}{$table}{A}->execute();
}
$dbhA->commit();

## Kick the sync and wait for it to finish
$bct->ctl('kick sync testfullcopy 0');

## Rows should be gone from B now
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Row with pkey of type $type is deleted from B};

    $res = [];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

## Now add two rows at once
for my $table (keys %tabletype) {
    my $type = $tabletype{$table};
    my $val2 = $val{$type}{2};
    my $val3 = $val{$type}{3};
    $sth{insert}{2}{$table}{A}->execute($val2);
    $sth{insert}{3}{$table}{A}->execute($val3);
}
$dbhA->commit();

## Kick the sync and wait for it to finish
$bct->ctl('kick sync testfullcopy 0');

## B should have the two new rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Two rows with pkey of type $type are copied to B};

    $res = [[2],[3]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

## Test out an update
for my $table (keys %tabletype) {
    my $type = $tabletype{$table};
    $SQL = "UPDATE $table SET inty=inty+10";
    $dbhA->do($SQL);
}
$dbhA->commit();
$bct->ctl('kick sync testfullcopy 0');

## B should have the updated rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Updates of two rows with pkey of type $type are copied to B};

    $res = [[12],[13]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

## Test insert, update, and delete all at once, across multiple transactions
for my $table (keys %tabletype) {
    my $type = $tabletype{$table};
    $SQL = "UPDATE $table SET inty=inty-3";
    $dbhA->do($SQL);
    $dbhA->commit();

    my $val4 = $val{$type}{4};
    $sth{insert}{4}{$table}{A}->execute($val4);
    $dbhA->commit();

    $SQL = "DELETE FROM $table WHERE inty = 10";
    $dbhA->do($SQL);
    $dbhA->commit();
}
$bct->ctl('kick sync testfullcopy 0');

## B should have the updated rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Updates of two rows with pkey of type $type are copied to B};

    $res = [[9],[4]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

for my $table (sort keys %tabletype) {
    my $type = $tabletype{$table};
    $dbhA->do("COPY $table($pkey{$table},inty,data1) FROM STDIN");
    my $val5 = $val{$type}{5};
    $val5 =~ s/\0//;
    $dbhA->pg_putcopydata("$val5\t5\tfive");
    $dbhA->pg_putcopyend();
    $dbhA->commit();
}
$bct->ctl('kick sync testfullcopy 0');

## B should have the new rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{COPY to A with pkey type $type makes it way to B};

    $res = [[9],[4],[5]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
}

## Modify the sync and have it go to B *and* C
$command =
"bucardo_ctl update sync testfullcopy set targetgroup=slaves";
$res = $bct->ctl($command);

## Before the sync reload, C should not have anything
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Row with pkey of type $type does not exist on C yet};

    $res = [];
    bc_deeply($res, $dbhC, $sql{select}{$table}, $t);
}

$command =
"bucardo_ctl reload sync testfullcopy";
$res = $bct->ctl($command);

$bct->ctl('kick sync testfullcopy 0');

## After the sync is reloaded and kicked, C will have all the rows
for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Row with pkey of type $type is copied to C};

    $res = [[9],[4],[5]];
    bc_deeply($res, $dbhC, $sql{select}{$table}, $t);
}

## Do an update, and have it appear on both sides
for my $table (keys %tabletype) {
    my $type = $tabletype{$table};
    $SQL = "UPDATE $table SET inty=55 WHERE inty = 5";
    $dbhA->do($SQL);
}
$dbhA->commit();
$bct->ctl('kick sync testfullcopy 0');

for my $table (sort keys %tabletype) {

    my $type = $tabletype{$table};
    $t = qq{Row with pkey of type $type is replicated to B};

    $res = [[9],[4],[55]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);

    $t = qq{Row with pkey of type $type is replicated to C};
    $res = [[9],[4],[55]];
    bc_deeply($res, $dbhC, $sql{select}{$table}, $t);
}

## Sequence testing

$dbhA->do("SELECT setval('bucardo_test_seq1', 123)");
$dbhA->commit();

$bct->ctl("kick testfullcopy 0");

$SQL = q{SELECT nextval('bucardo_test_seq1')};
$t='Fullcopy replicated a sequence properly to B';
$result = [[123+1]];
bc_deeply($result, $dbhB, $SQL, $t);

$t='Fullcopy replicated a sequence properly to C';
bc_deeply($result, $dbhC, $SQL, $t);

$dbhA->do("SELECT setval('bucardo_test_seq1', 223, false)");
$dbhA->commit();

$bct->ctl("kick testfullcopy 0");

$SQL = q{SELECT nextval('bucardo_test_seq1')};
$t='Fullcopy replicated a sequence properly with a false setval to B';
$result = [[223]];
bc_deeply($result, $dbhB, $SQL, $t);

$t='Fullcopy replicated a sequence properly with a false setval to C';
bc_deeply($result, $dbhC, $SQL, $t);

$dbhA->do("SELECT setval('bucardo_test_seq1', 345, true)");
$dbhA->commit();

$bct->ctl("kick testfullcopy 0");
wait_for_notice($dbhX, 'bucardo_syncdone_testfullcopy', 5);

$SQL = q{SELECT nextval('bucardo_test_seq1')};
$t='Fullcopy replicated a sequence properly with a true setval to B';
$result = [[345+1]];
bc_deeply($result, $dbhB, $SQL, $t);

$t='Fullcopy replicated a sequence properly with a true setval to C';
$result = [[345+1]];
bc_deeply($result, $dbhC, $SQL, $t);

## Add another slave on the fly
$t = q{Added database D to group 'slaves'};
$command =
"bucardo_ctl add dbgroup slaves D";
$res = $bct->ctl($command);
like ($res, qr{Added database "D" to group "slaves"}, $t);

## Test out customselect - update just the id column
$t = q{Set customselect on table bucardo_test1};
$command =
"bucardo_ctl update table bucardo_test1 customselect='SELECT id FROM bucardo_test1'";
$res = $bct->ctl($command);
like ($res, qr{\Qcustomselect : changed from (null) to "SELECT id FROM bucardo_test1"}, $t);

$t = q{Set usecustomselect to true for sync testfullcopy};
$command =
"bucardo_ctl update sync testfullcopy usecustomselect=true";
$res = $bct->ctl($command);
like ($res, qr{usecustomselect : changed from "f" to "true"}, $t);

$t = q{Reloaded the sync testfullcopy};
$command =
"bucardo_ctl reload sync testfullcopy";
$res = $bct->ctl($command);
like ($res, qr{Reloading sync testfullcopy...DONE!}, $t);

## Update both id and inty, but only the former should get propagated
$dbhA->do("UPDATE bucardo_test1 SET id=id + 100, inty=inty + 100");
$dbhA->commit();

$bct->ctl('kick sync testfullcopy 0');

$t = q{Table bucardo_test1 copied only some rows to B due to customselect};
$SQL = 'SELECT id, inty FROM bucardo_test1';
$result = [[102,undef], [104,undef], [105,undef]];
bc_deeply($result, $dbhB, $SQL, $t);

$t = q{Table bucardo_test2 copied all some rows to B due to lack of customselect};
$SQL = 'SELECT id, inty FROM bucardo_test2';
$result = [[1234569,9],[1234571,4],[1234572,55]];
bc_deeply($result, $dbhB, $SQL, $t);

## Now try truncate mode instead of delete
$t = q{Reloaded the sync testfullcopy};
$command =
"bucardo_ctl update sync testfullcopy deletemethod=truncate usecustomselect=f";
$res = $bct->ctl($command);
like ($res, qr{Changes made to sync}, $t);

$t = q{Reloaded the sync testfullcopy};
$command =
"bucardo_ctl reload sync testfullcopy";
$res = $bct->ctl($command);
like ($res, qr{Reloading sync testfullcopy...DONE!}, $t);

$bct->ctl("kick testfullcopy 0");

my $table = 'bucardo_test1';

my $type = $tabletype{$table};
$res = [[109],[104],[155]];

$t = qq{Row with pkey of type $type is copied to B};
bc_deeply($res, $dbhB, $sql{select}{$table}, $t);

$t = qq{Row with pkey of type $type is copied to C};
bc_deeply($res, $dbhC, $sql{select}{$table}, $t);

exit;
