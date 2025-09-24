#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use JSON qw(decode_json);
use LWP::UserAgent;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use Getopt::Long;
use POSIX qw(strftime);

# non-emoji pictographic characters
# https://character.construction/picto

# --- CONFIGURATION ---
my $script_dir = dirname(__FILE__);
my $REPO_FILE = $ENV{REPO_FILE} || catfile($script_dir, 'repos.txt');
my $CACHE_DURATION = $ENV{CACHE_DURATION} || 3600;  # 1 hour default
my $DB_FILE = "versions.db";
my $GITHUB_TOKEN = $ENV{GITHUB_TOKEN};

# --- OPTIONS ---
my $format = 'table';
my $debug = 0;

# --- COLORS ---
my %colors = (
    GREEN  => "\033[0;32m",
    YELLOW => "\033[0;33m", 
    RED    => "\033[0;31m",
    CYAN   => "\033[0;36m",
    NC     => "\033[0m"
);

# --- ERROR MESSAGES ---
my %ERRORS = (
    E_NO_TOKEN => qq{
==============================[ ERROR ]===============================

[!] GITHUB_TOKEN environment variable is not set.

------------------------------[ SOLUTION ]------------------------------

You must create a GitHub Personal Access Token and export it as an
environment variable.

  > Go here to create a new token:
    https://github.com/settings/personal-access-tokens/new

  > Required Settings:
    • Repository access:  All repositories
    • Permissions:        Contents -> Read-only

------------------------------------------------------------------------
},
    E_API_FAIL => "Failed to fetch version from GitHub API",
    E_NO_REPOS => "Repository file not found at"
);

# --- FETCH STRATEGIES ---
my %FETCH_STRATEGIES = (
    'git/git'        => \&fetch_strategy_git_ls_remote,
    'python/cpython' => \&fetch_strategy_git_ls_remote,
);

# --- GLOBAL VARIABLES ---
my $dbh;
my $ua;

# --- HELPER --- (Keep only one definition)
sub debug_print {
    my ($msg) = @_;
    print STDERR "DEBUG: $msg\n" if $debug;
}

# --- MAIN ---
sub main {
    GetOptions(
        'debug'    => \$debug,
        'format=s' => \$format,
        'help|h'   => \&show_help,
    ) or die "Error in command line arguments\n";
    
    # Check token before doing anything else
    unless ($GITHUB_TOKEN && $GITHUB_TOKEN =~ /^gh[ps]_/) {
        if (!$GITHUB_TOKEN) {
            die_with_error('E_NO_TOKEN');
        } else {
            warn "$colors{YELLOW}Warning: GITHUB_TOKEN doesn't look like a valid token$colors{NC}\n";
        }
    }
    
    debug_print("Using GitHub token: " . substr($GITHUB_TOKEN, 0, 8) . "...");

    init_db();
    init_http_client();
    
    my $time_str = calculate_last_success();
    print_header($time_str) if $format eq 'table';
    
    my $current_category = '';
    my $current_time = time();
    
    die_with_error('E_NO_REPOS', $REPO_FILE) unless -f $REPO_FILE;
    
    open my $fh, '<', $REPO_FILE or die "Can't open $REPO_FILE: $!";
    
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;  # skip empty lines and comments
        
        my ($category, $repo) = split /,/, $line, 2;
        next unless $category && $repo;
        
        $category =~ s/^\s+|\s+$//g;  # trim whitespace
        $repo =~ s/^\s+|\s+$//g;
        
        next unless $category && $repo;
        
        if ($category ne $current_category && $format eq 'table') {
            print "\n$colors{CYAN}--- $category ---$colors{NC}\n";
            $current_category = $category;
        }
        
        process_repo($repo, $current_time);
    }
    
    close $fh;
    print_footer() if $format eq 'table';
    
    $dbh->disconnect();
}

# --- DATABASE FUNCTIONS ---
sub init_db {
    $dbh = DBI->connect("dbi:SQLite:dbname=$DB_FILE", "", "", {
        RaiseError => 1,
        AutoCommit => 1,
    }) or die "Cannot connect to database: $DBI::errstr";
    
    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS versions (
            repo TEXT PRIMARY KEY,
            version TEXT,
            last_checked INTEGER,
            status TEXT
        )
    });
}

sub get_cached_data {
    my ($repo) = @_;
    
    my $sth = $dbh->prepare("SELECT version, last_checked, status FROM versions WHERE repo = ?");
    $sth->execute($repo);
    my $row = $sth->fetchrow_hashref();
    $sth->finish();
    
    return $row || {};
}

sub update_record {
    my ($repo, $version, $status) = @_;
    my $check_time = time();
    
    my $sth = $dbh->prepare("INSERT OR REPLACE INTO versions (repo, version, last_checked, status) VALUES (?, ?, ?, ?)");
    $sth->execute($repo, $version, $check_time, $status);
    $sth->finish();
    
    return $check_time;
}

sub calculate_last_success {
    my $sth = $dbh->prepare("SELECT MAX(last_checked) FROM versions WHERE status = 'OK'");
    $sth->execute();
    my ($last_success) = $sth->fetchrow_array();
    $sth->finish();
    
    if ($last_success) {
        my $hours_ago = int((time() - $last_success) / 3600);
        return "(last success: ${hours_ago}h ago)";
    }
    
    return "";
}

# --- HTTP CLIENT (Fixed missing brace) ---
sub init_http_client {
    $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => 'version-checker-perl/1.0',
        ssl_opts => {
            verify_hostname => 0,  # Testing Disable SSL verification
            SSL_verify_mode => 0,
        },
    );
}

# --- FETCH STRATEGIES ---
sub fetch_strategy_github_api {
    my ($repo) = @_;
    
    my $url = "https://api.github.com/repos/$repo/releases/latest";
    debug_print("Fetching: $url");

    my $request = HTTP::Request->new(GET => $url);
    $request->header('Authorization' => "Bearer $GITHUB_TOKEN");
    
    my $response = $ua->request($request);
    debug_print("Response code: " . $response->code);
    
    unless ($response->is_success) {
        debug_print("API Error: " . $response->status_line);
        return undef;
    }
    
    my $data = eval { decode_json($response->content) };
    if ($@) {
        debug_print("JSON Parse Error: $@");
        return undef;
    }
    
    debug_print("Got version: " . ($data->{tag_name} || 'null'));
    return $data->{tag_name};
}

sub fetch_strategy_git_ls_remote {
    my ($repo) = @_;
    
    my $cmd = qq{GIT_TERMINAL_PROMPT=0 git ls-remote --tags --sort="v:refname" "https://github.com/$repo" 2>/dev/null | grep -v -E '(rc|a|b)[0-9]*\$' | tail -n 1 | sed 's/.*\\///; s/\\^{}//'};
    
    my $result = `$cmd`;
    chomp $result if $result;
    
    return $result || undef;
}

sub fetch_live_version {
    my ($repo) = @_;
    
    my $strategy = $FETCH_STRATEGIES{$repo} || \&fetch_strategy_github_api;
    my $raw_version = $strategy->($repo);
    
    return undef unless $raw_version && $raw_version ne 'null';
    
    # Clean version string
    $raw_version =~ s/^v//;           # remove 'v' prefix
    $raw_version =~ s/^jq-//;         # remove 'jq-' prefix
    $raw_version =~ s/^v[iv]m-//;     # remove 'vim-' or 'vi-' prefix
    
    return $raw_version;
}

# --- VERSION PROCESSING ---
sub process_repo {
    my ($repo, $current_time) = @_;
    
    my $cached = get_cached_data($repo);
    my $cached_version = $cached->{version} || '';
    my $last_checked = $cached->{last_checked} || 0;
    my $last_status = $cached->{status} || '';
    
    my ($version_to_print, $status, $color, $actual_check_time);
    
    if (is_cache_valid($cached_version, $last_checked, $current_time)) {
        # Use cached data
        $version_to_print = $cached_version;
        $status = "OK (Cached)";
        $color = $colors{GREEN};
        $actual_check_time = $last_checked;
        
        if ($last_status eq 'FAILED') {
            $status = "Stale (Failed Last)";
            $color = $colors{YELLOW};
        }
    } else {
        # Fetch live data
        my $live_version = fetch_live_version($repo);
        
        if ($live_version) {
            $version_to_print = $live_version;
            $status = "OK (Live)";
            $color = $colors{GREEN};
            $actual_check_time = update_record($repo, $version_to_print, 'OK');
        } else {
            # Handle failure without dying
            $version_to_print = $cached_version || "N/A";
            $actual_check_time = update_record($repo, '', 'FAILED');
            
            if ($last_status eq 'FAILED') {
                $status = "FAILED (Again)";
                $color = $colors{RED};
            } else {
                $status = "FAILED (Once)";
                $color = $colors{YELLOW};
            }
            
            debug_print("Failed to fetch version for $repo");
        }
    }
    
    print_repo_line($repo, $version_to_print, $status, $color, $actual_check_time);
}

sub is_cache_valid {
    my ($version, $last_check_time, $current_time) = @_;
    
    return 0 unless $version;
    return 0 unless $last_check_time && $last_check_time =~ /^\d+$/;
    
    return ($current_time - $last_check_time) < $CACHE_DURATION;
}

# --- OUTPUT FUNCTIONS ---
sub print_header {
    my ($time_str) = @_;
    
    print "☞ Checking upstream versions $time_str...\n";
    print "----------------------------------------------------------------\n";
    printf "%-25s %-15s %s\n", "Repository:", "Version:", "Status:";
    print "----------------------------------------------------------------\n";
}

sub print_repo_line {
    my ($repo, $version, $status, $color, $check_time) = @_;
    
    my $human_date = strftime("%Y-%m-%d %H:%M", localtime($check_time || time()));
    
    if ($format eq 'table') {
        printf "%-30s %-15s ${color}%-20s$colors{NC} %s\n", 
               "$repo:", $version, $status, $human_date;
    } elsif ($format eq 'json') {
        my $data = {
            repo => $repo,
            version => $version,
            status => $status,
            last_checked => $human_date,
        };
        print encode_json($data) . "\n";
    }
}

sub print_footer {
    print "----------------------------------------------------------------\n";
}

# --- ERROR HANDLING ---
sub die_with_error {
    my ($error_code, $extra_info) = @_;
    
    my $error_message = $ERRORS{$error_code} || "Unknown error occurred";
    $extra_info = $extra_info ? " $extra_info" : "";
    
    print STDERR "$colors{RED}Error: $error_message$extra_info$colors{NC}\n";
    exit 1;
}

sub show_help {
    print <<'EOF';
Usage: check-versions.pl [OPTIONS]

OPTIONS:
  --format=FORMAT    Output format: table, json (default: table)
  --debug            Enable debug output
  --help, -h         Show this help message

ENVIRONMENT:
  GITHUB_TOKEN       GitHub Personal Access Token (required)
  REPO_FILE          Path to repos.txt file (default: ./repos.txt)
  CACHE_DURATION     Cache duration in seconds (default: 3600)

EOF
    exit 0;
}

# --- RUN ---
main() unless caller;

1;
