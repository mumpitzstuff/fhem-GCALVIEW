##############################################################################
#
#     57_GCALVIEW.pm
#     FHEM module to visualize google calendar content.
#
#     Author: Achim Winkler
#
##############################################################################

package main;

use strict;
use warnings;
use Blocking;
use JSON;


sub GCALVIEW_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = 'GCALVIEW_Define';
  $hash->{UndefFn}  = 'GCALVIEW_Undefine';
  $hash->{NotifyFn} = 'GCALVIEW_Notify'; 
  $hash->{GetFn}    = 'GCALVIEW_Get';
  $hash->{AttrFn}   = 'GCALVIEW_Attr';
  $hash->{AttrList} = 'updateInterval '.
                      'calendarDays '.
                      'calendarType:standard,waste '.
                      'alldayText '.
                      'weekdayText '.
                      'maxEntries '.
                      'includeStarted:1 '.
                      'sourceColor:textField-long '.
                      'disable:1 '.
                      'filterSummary '.
                      'filterLocation '.
                      'filterDescription '.
                      'filterSource '.
                      'filterAuthor '.
                      'filterOverall '.
                      $readingFnAttributes;

  return undef;
}


sub GCALVIEW_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def);
  
  return 'Usage: define <name> GCALVIEW <timeout>'  if (@args < 3);
  
  my ($name, $type, $timeout) = @args;
  return 'The timeout value has to be at least 10s'  if ($timeout < 10);
  
  $hash->{NOTIFYDEV} = 'global'; 
  $hash->{TIMEOUT} = $timeout;

  delete $hash->{helper}{RUNNING_PID};
  
  $attr{$name}{'updateInterval'} = 3600 if (!defined($attr{$name}{'updateInterval'}));
  
  readingsSingleUpdate($hash, 'state', 'Initialized', 1);

  Log3 $name, 3, 'GCALVIEW defined with timeout '.$timeout;

  return undef;
}


sub GCALVIEW_Undefine($$)
{
  my ($hash, $arg) = @_;
  
  RemoveInternalTimer($hash);
  BlockingKill($hash->{helper}{RUNNING_PID}) if (defined($hash->{helper}{RUNNING_PID}));
  
  return undef;
}


sub GCALVIEW_Notify($$)
{
  my ($hash, $dev) = @_;
  
  return if (!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if (IsDisabled($hash->{NAME})) 
  {
    readingsSingleUpdate($hash, 'state', 'disabled', 0);
  }
  else
  {
    GCALVIEW_SetNextTimer($hash, 15);
  }
  
  return undef;
} 


sub GCALVIEW_Attr($$$$) {
  my ($command, $name, $attribute, $value) = @_;
  my $hash = $defs{$name};

  Log3 $hash->{NAME}, 5, $hash->{NAME}.'_Attr: Attr '.$attribute.'; Value '.$value;

  if ($command eq 'set') 
  {
    if ($attribute eq 'updateInterval')
    {
      if (($value !~ /^\d+$/) || ($value < 60))
      {
        return 'updateInterval is required in s (default: 3600, min: 60)';
      }
    }
    elsif ($attribute eq 'disable')
    {
      if ($value eq '1')
      {
        RemoveInternalTimer($hash);
        
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
      }
      else
      {
        GCALVIEW_SetNextTimer($hash, 0);
        
        readingsSingleUpdate($hash, 'state', 'Initialized', 1);
      }
    }
    elsif ($attribute eq 'calendarDays')
    {
      if ($value !~ /^\d+$/)
      {
        return 'calendarDays is required in days (any positive number)';
      }
    }
    elsif ($attribute eq 'sourceColor')
    {
      my $fail = 0;
      my @sourceColors = split('\s*,\s*' , $value);
            
      if (@sourceColors)
      {
        foreach (@sourceColors)
        { 
          @_ = split('\s*:\s*', $_);
          
          if (!@_)
          {
            $fail = 1;
            last;
          }
        }
      }
      else
      {
        $fail = 1;
      }
      
      if ($fail)
      {
        return 'sourceColor is required in format: <source>:<color>,<source>:<color>,...';
      }
    }
    elsif ($attribute eq 'maxEntries')
    {
      if (($value !~ /^\d+$/) || ($value > 200) || (0 == $value))
      {
        return 'maxEntries must be a number and is limited to the range: 1 - 200';
      }
    }
    elsif ($attribute eq 'weekdayText')
    {
      @_ = split('\s*,\s*', $value);
      
      if (scalar(@_) != 7)
      {
        return 'weekdayText must be a comma separated list of 7 days: Monday,Tuesday,...';
      }
    }
    elsif ($attribute eq 'filterSummary' ||
           $attribute eq 'filterLocation' ||
           $attribute eq 'filterDescription' ||
           $attribute eq 'filterSource' ||
           $attribute eq 'filterAuthor' ||
           $attribute eq 'filterOverall')
    {
      eval{qr/$value/};
      
      if ($@)
      {
        return 'regular expression is wrong: '.$@;
      }        
    }
  }
 
  return undef;
}


sub GCALVIEW_SetNextTimer($$)
{
  my ($hash, $timer) = @_;
  
  Log3 $hash->{NAME}, 5, $hash->{NAME}.'_SetNextTimer: set next timer';
  
  RemoveInternalTimer($hash);
  if (!defined($timer))
  {
    InternalTimer(gettimeofday() + AttrVal($hash->{NAME}, 'updateInterval', 3600), 'GCALVIEW_Start', $hash, 0);
  }
  else
  {
    InternalTimer(gettimeofday() + int(rand(30)) + $timer, 'GCALVIEW_Start', $hash, 0);
  }
}


sub GCALVIEW_Get($$@) {
  my ($hash, $name, @aa) = @_;
  my ($cmd, $arg) = @aa;
    
  if ($cmd eq 'update') 
  {
    GCALVIEW_Start($hash);
  }
  else 
  {
    my $list = 'update:noArg';
      
    return 'Unknown argument '.$cmd.', choose one of '.$list;
  }

  return undef;
} 


sub GCALVIEW_Start($)
{
  my ($hash) = @_;

  return undef if (IsDisabled($hash->{NAME}));

  if (!(exists($hash->{helper}{RUNNING_PID}))) 
  {
    GCALVIEW_SetNextTimer($hash, undef);
    
    $hash->{helper}{RUNNING_PID} = BlockingCall('GCALVIEW_DoRun', $hash->{NAME}, 'GCALVIEW_DoEnd', $hash->{TIMEOUT}, 'GCALVIEW_DoAbort', $hash);
  } 
  else 
  {
    Log3 $hash->{NAME}, 3, $hash->{NAME}.' blocking call already running';
    GCALVIEW_SetNextTimer($hash, undef);
  }
}


sub GCALVIEW_DoRun(@)
{
  my ($string) = @_;
  my ($name, $timeout) = split("\\|", $string);
  my @calList = ();
  my $calData = '';
  my $result;
  my $calendarDays = AttrVal($name, 'calendarDays', undef);
  my $calendarPeriod = '';
  my $calFilter = AttrVal($name, 'calendarFilter', undef);
  my $includeStarted = (1 == AttrVal($name, 'includeStarted', 0) ? '--started' : '');
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  my $today = sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
   
  Log3 $name, 5, $name.'_DoRun: start running';
  
  # calendar filter attribute already set? 
  if (!defined($calFilter))
  {
    # get list of calendars
    ($calData, $result) = ($_ = qx(gcalcli list 2>&1), $? >> 8);
    
    if (0 != $result)
    {
      Log3 $name, 3, $name.": gcalcli list";
      Log3 $name, 3, $name.': something went wrong (check your parameters) - '.$calData;
      
      $calData = '';
    }
    else
    {
      #Log3 $name, 5, $name.': '.$calData;
      
      while (m/(?:owner|reader)\s+(.+)\s*/g)
      {
        push(@calList, $1);
      }
    }
    
    $calFilter = '';
  }
  else
  {
    # filter calendars if attribute calFilter is available
    @_ = split(/\s*,\s*/, $calFilter);
    
    for (@_) 
    {
      $_ = '"'.$_.'"';
    }
    
    $calFilter = '--calendar '.join(' --calendar ', @_);
  }
  
  # calculate end date if needed (5 days is the default)
  if (defined($calendarDays))
  {
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + (86400 * $calendarDays));
    
    $calendarPeriod = $today.' '.sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
  }
  
  # get all calendar entries
  ($calData, $result) = ($_ = qx(gcalcli agenda $calendarPeriod $calFilter --detail_all $includeStarted --tsv 2>&1), $? >> 8);  
  
  if (0 != $result)
  {
    Log3 $name, 3, $name.": gcalcli agenda $calendarPeriod $calFilter --detail_all $includeStarted --tsv";
    Log3 $name, 3, $name.': something went wrong (check your parameters) - '.$calData;
    
    $calData = '';
  }
  else
  {
    # split the results by lines
    my @entry = split("\n" , $calData);
    my @calStruct = ();
    my $filterSummary = AttrVal($name, 'filterSummary', undef);
    my $filterLocation = AttrVal($name, 'filterLocation', undef);
    my $filterDescription = AttrVal($name, 'filterDescription', undef);
    my $filterSource = AttrVal($name, 'filterSource', undef);
    my $filterAuthor = AttrVal($name, 'filterAuthor', undef);
    my $filterOverall = AttrVal($name, 'filterOverall', undef);
    my $sourceColor;
    my @sourceColors = split('\s*,\s*' , AttrVal($name, 'sourceColor', ''));
    
    #Log3 $name, 5, $name.': '.$calData;
    
    foreach $_ (@entry)
    {
      # split each line by tabs
      @_ = split("\t", $_);
      
      # output must have exactly 11 fields of data
      if (11 == scalar(@_))
      {
        # apply some content filters
        next if ((defined($filterSummary) && ($_[6] =~ /$filterSummary/)) ||
                 (defined($filterLocation) && ($_[7] =~ /$filterLocation/)) ||
                 (defined($filterDescription) && ($_[8] =~ /$filterDescription/)) ||
                 (defined($filterSource) && ($_[9] =~ /$filterSource/)) ||
                 (defined($filterAuthor) && ($_[10] =~ /$filterAuthor/)) ||
                 (defined($filterOverall) && (($_[6] =~ /$filterOverall/) || 
                                              ($_[7] =~ /$filterOverall/) ||
                                              ($_[8] =~ /$filterOverall/) ||
                                              ($_[9] =~ /$filterOverall/) ||
                                              ($_[10] =~ /$filterOverall/))));      
      
        # generate source color and add an additonal data field
        $sourceColor = 'white';
        foreach (@sourceColors)
        { 
          my ($source, $color) = split('\s*:\s*', $_); 
          
          if (-1 != index($_[9], $source))
          { 
            $sourceColor = $color;
            
            last;
          }
        };
        
        push(@_, $sourceColor);
        push(@calStruct, [@_]);
      }
      else
      {
        Log3 $name, 3, $name.': something went wrong (invalid gcalcli output) - '.join(', ', @_);;
      }
    }
    
    # encode filtered calendar entries
    $calData = encode_json(\@calStruct);
    
    #Log3 $name, 5, $name.': '.$calData;
  }
  
  # encode calendar list
  $_ = encode_base64(join(',', @calList), '');

  return $name.'|'.$_.'|'.$calData;
}


sub GCALVIEW_DoEnd($)
{
  my ($string) = @_;
  my ($name, $calList, $calDataJson) = split("\\|", $string);
  my $hash = $defs{$name};
  my @calData;
  my $cterm_new = 0;
  my $ctoday_new = 0;
  my $ctomorrow_new = 0;
   
  Log3 $name, 5, $name.'_DoEnd: end running';
  
  # decode results
  $calList = decode_base64($calList);
  @calData = @{decode_json($calDataJson)};
  
  if ('' ne $calList)
  {
    $calList =~ s/\s/#/g;
    addToDevAttrList($name, 'calendarFilter:multiple-strict,'.$calList);
  }
  
  # clear all readings
  delete($hash->{READINGS});
  
  # start update of readings
  readingsBeginUpdate($hash);
  
  if (scalar(@calData))
  {
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    my $weekday = $wday;
    my $today = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900);
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + 86400);
    my $tomorrow = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900); 
    my @readingPrefix = ('t_', 'today_', 'tomorrow_');
    my $weekDayArr = AttrVal($name, 'weekdayText', undef);
    my $alldayText = AttrVal($name, 'alldayText', 'all-day');
  
    foreach (@calData)
    {
      # mapping
      # 0 = start date
      # 1 = start time
      # 2 = end date
      # 3 = end time
      # 4 = link
      # 5 = ?
      # 6 = summary
      # 7 = location
      # 8 = description
      # 9 = calendar
      # 10 = author
      # additional generated attribute
      # 11 = sourcecolor
            
      my $startDate = @$_[0];
      my $startTime = @$_[1];
      my $endDate = @$_[2];
      my $endTime = @$_[3];
      my $url = @$_[4];
      my $summary = @$_[6];
      my $location = @$_[7];
      my $description = @$_[8];
      my $calendar = @$_[9];
      my $author = @$_[10];
      my $sourceColor = @$_[11];
      my ($startYear, $startMonth, $startDay) = split("-", $startDate);
      my ($endYear, $endMonth, $endDay) = split("-", $endDate);
      my $eventDate = fhemTimeLocal(0, 0, 0, $startDay, $startMonth - 1, $startYear - 1900);
      my $daysleft = floor(($eventDate - time) / 60 / 60 / 24 + 1);
      my $daysleftLong;
      my $startDateStr = $startDay.'.'.$startMonth.'.'.$startYear;
      my $endDateStr = $endDay.'.'.$endMonth.'.'.$endYear;
      my $timeShort;
      my $weekdayStr;
    
      # generate string daysleft
      if (0 == $daysleft)
      {
        $daysleftLong = 'today';
      }
      elsif (1 == $daysleft)
      {
        $daysleftLong = 'tomorrow';
      }
      else
      {
        $daysleftLong = 'in '.$daysleft.' days';
      }
      
      # generate timeshort
      if (($startTime eq "00:00") && ($endTime eq "00:00") && ($startDate ne $endDate))
      {
        $timeShort = $alldayText;
      }
      else
      {
        $timeShort = $startTime.' - '.$endTime;
      }
      
      # generate weekdaytext
      if (!defined($weekDayArr))
      {
        @_ = ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday');
        $weekdayStr = $_[(($weekday - 1 + $daysleft) % 7)];        
      }
      else
      {
        @_ = split('\s*,\s*', $weekDayArr);
        $weekdayStr = $_[(($weekday - 1 + $daysleft) % 7)];
      }
      
      # loop 3 times to generate the overall appointment list, the appointment list for today and the appointment list for tomorrow
      for (my $i = 0; $i < 3; $i++)
      {
        if ((0 == $i) ||
            (1 == $i && $startDateStr eq $today) ||
            (2 == $i && $startDateStr eq $tomorrow))
        {
          my $counter;
          
          if (0 == $i)
          {
            $counter = \$cterm_new;
          }
          elsif (1 == $i)
          {
            $counter = \$ctoday_new;
          }
          elsif (2 == $i)
          {
            $counter = \$ctomorrow_new;
          }
          
          my $counterLength = 3 - length($$counter + 1);
          
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_bdate', $startDateStr);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_btime', $startTime);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleft', $daysleft);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleftLong', $daysleftLong);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_edate', $endDateStr);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_etime', $endTime);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_location', $location);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_description', $description);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_author', $author);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_source', $calendar);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_sourcecolor', $sourceColor);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_summary', $summary);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_timeshort', $timeShort);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_weekday', $weekdayStr);
          readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_url', '<html><a href="'.$url.'" target="_blank">link</a></html>');
          
          $$counter++;
        }
      }
      
      last if ($cterm_new >= AttrVal($name, 'maxEntries', 200));
    }
  }
        
  readingsBulkUpdate($hash, 'c-term', $cterm_new);
  readingsBulkUpdate($hash, 'c-today', $ctoday_new);
  readingsBulkUpdate($hash, 'c-tomorrow', $ctomorrow_new);
  readingsBulkUpdate($hash, 'state', 't: '.$cterm_new.' td: '.$ctoday_new.' tm: '.$ctomorrow_new);
  readingsEndUpdate($hash, 1); 
  
  delete($hash->{helper}{RUNNING_PID});
}


sub GCALVIEW_DoAbort($)
{
  my ($hash) = @_;
  
  delete($hash->{helper}{RUNNING_PID});
  
  Log3 $hash->{NAME}, 3, 'BlockingCall for '.$hash->{NAME}.' aborted';
}

1;

=pod
=begin html

<a name="GCALVIEW"></a>
<h3>GCALVIEW</h3>

=end html
=cut
