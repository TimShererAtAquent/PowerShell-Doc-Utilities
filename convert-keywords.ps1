﻿<#
.SYNOPSIS 
Converts A keywords and assetIDs to URLs

.DESCRIPTION
Pandoc leaves A keywords and assetIDs in .md files. This script replaces them with short form MSDN URLs.
Runs recursively over each .md file, replacing remaining A keywords and assetIDs until none are left.
Replaces each .md file in-place.
Requires read perms on MSDN Reporting SG.
To see debug messages, uncomment $DebugPreference line below.
    
.PARAMETER InputPath
Directory containing .md files generated by pandoc.exe.

.NOTES  
    File Name  : convert-keywords.ps1
    Author     : Ted Hudek
    Requires   : PowerShell V2  
    Created    : 10/5/15
    Updated    : 3/4/16

.EXAMPLE
    .\convert-keywords.ps1 <md_input_path>
  
#>

param(
  [string]$InputPath
)

<#
There are two ways to do the db access in this script. One is by importing the sqlps module and then using the Invoke-SqlCmd cmdlet.
This is not preferred for turnkey operation because users have to go find that module and install it.
The preferred way is by using the function Invoke-SQL, defined inline below, because it does the same thing through .NET.
If you run into trouble with it, however, you can uncomment the Import-Module statement below and then switch the comments on the two SQL queries
to use the module instead.
#>
##Import-Module sqlps -DisableNameChecking -noclobber

# $DebugPreference = 'Continue'

$DBServer='reporting.mtps.glbdns2.microsoft.com'
$db='MSDNContentCache'

# define variables of script scope, note that we reference these explicitly inside the function, which has its own child scope
$ktbl=@{} # hash table where we will cache keyword lookup table 
$projectsQueried=@() # array where we track projects we have already queried
$i=1

function Invoke-SQL {
      param(
          [Parameter(Mandatory=$true)]
          [string]$sqlQuery,
          [Parameter(Mandatory=$true)]
          [string]$ServerInstance,
          [Parameter(Mandatory=$true)]
          [string]$Database,
          [int]$QueryTimeout
      )
       
      $ConnectString="Data Source=${ServerInstance}; Integrated Security=SSPI; Initial Catalog=${Database}; Min Pool Size=1"
       
      $Conn=New-Object System.Data.SqlClient.SQLConnection($ConnectString)
      $Command = New-Object System.Data.SqlClient.SqlCommand($sqlQuery,$Conn)
      $Command.CommandTimeout = $QueryTimeout
      $Conn.Open()
       
      $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $Command
      $DataSet = New-Object System.Data.DataSet
      $null = $Adapter.Fill($DataSet)

      $Conn.Close()
      $DataSet.Tables[0]

      $DataSet.Dispose()
      $Adapter.Dispose()
      $Command.Dispose()

} 


function testmatch($str){
    
    $url=""

    if (($str -match ']\((\w*?\.(?!md[#\)])(?!htm[#\)])[\w-]*?)(#[\w-]*?)?\)'  ) -or  ( $str -match '<a href=\"(\w*?\.(?!md[#\"])(?!htm[#\"])[\w-]*?)(#[\w-]*?)?\">')) { # capture A keywords but not filename.md or filename.htm
       
        $m=$matches[1] # index 1 gives us just the capture group (0 is the whole match)
        $bookmark=$matches[2] # for example, project.topic#bookmark

        Write-Debug "Attempting to match $($m) in $($fileobj.name)" # $m is in the form project.topic
    
        # search lookup table for the keyword 

        $row=$script:ktbl[$m]

        # if no row, either we haven't queried for the hxs yet, or we did query previously but the keyword isn't in the database

        if(!$row){  
        
            # extract project name from keyword

            $m -match '^(.*?)\.' | Out-Null 
            $hxs=$matches[1] 

            if($scope:projectsQueried -contains $hxs){"$($hxs) project in lookup table but keyword $($m) not found."; $exitcode=1; $host.SetShouldExit($exitcode); exit}

            # we have not already queried for this hxs, so let's do it

            $DBQuery = "
            SELECT keywordTerm, contentId, value as PreferredLib FROM [MSDNContentCache].[dbo].[FriendlycontentItemKeyword] kw
            JOIN [MSDNContentCache].dbo.FriendlycontentItemProperty p ON p.contentItemId = kw.contentItemId
            WHERE kw.stateid=3 and kw.locale='en-us' and kw.keywordTypeId=1
                   and propertyTypeName = 'PreferredLib'
                   and kw.keywordTerm LIKE ('$hxs.%')
            "
            
            try{

                $queryresults=Invoke-SQL -sqlQuery $DBQuery -ServerInstance $DBServer -Database $db -QueryTimeout 120 -ErrorAction Stop ## this line uses the inline function above (.NET)
                ##$script:ktbl+=Invoke-SqlCmd $DBQuery -serverinstance $DBServer -QueryTimeout 120 -ErrorAction Stop ## this line uses the SQLPS module (and dates from when $ktbl was an array instead of a hash table)
            
            }

            catch{

                Write-Output "Error connecting to db server.  Ensure that you have perms on the MSDN Reporting SG."
                $_.Exception.message
                $exitcode=1
                $host.SetShouldExit($exitcode) 
                exit
            
            }

            # occasionally there are duplicate keywordTerms, so ensure these are unique before loading query results into the hash table
            $queryresults | sort keywordterm -Unique | select -Property keywordTerm,contentId,PreferredLib | %{$script:ktbl.Add($_.keywordTerm,@($_.contentId,$_.PreferredLib))}

            $script:projectsQueried+=$hxs

            # try to get row again 
                
            $row=$script:ktbl[$m]
            if(!$row){ "$($hxs) project in lookup table but keyword $($m) not found."; $exitcode=1; $host.SetShouldExit($exitcode); exit}
        }

        if(!$url){ # if url is still empty (hasn't become BUGBUG)

            $contentid=$row[0]
            $preferredLib=$row[1]
            $url='https://msdn.microsoft.com' + $preferredLib + '/' + $contentid
            $url=$url.toLower()

        }

        Write-Debug "Replacing $($m) with $($url)"

        # use replace operator to replace all occurrences of the keyword in the file, then call this function recursively to look for other keywords
        # First wrap each string in parentheses to ensure we only replace entire RIDs.
        $m="\($m$bookmark\)"
        $url="($url$bookmark)"
        testmatch($str -replace (($m) -replace '\.','\.'),$url) 
        # in inner parentheses, convert abc.def to abc\.def, then pass abc\.def string as a regex in the outer

    }
    
    elseif($str -match 'a href=\"((\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1})\">') { # look for guids (assetids) in <a href>

        $m=$matches[1]

        # query for a single assetid
    
        $DBQuery = "
        SELECT distinct contentId, value as PreferredLib FROM [MSDNContentCache].[dbo].[FriendlycontentItemKeyword] kw
        JOIN [MSDNContentCache].dbo.FriendlycontentItemProperty p ON p.contentItemId = kw.contentItemId
        WHERE kw.stateid=3 and kw.locale='en-us' and kw.keywordTypeId=1 and assetID = '$m'
               and propertyTypeName = 'PreferredLib'
        "
        
        try{

            $queryresults=Invoke-SQL -sqlQuery $DBQuery -ServerInstance $DBServer -Database $db -QueryTimeout 240 -ErrorAction Stop
            ##$queryresults=Invoke-SqlCmd $DBQuery -serverinstance $DBServer -QueryTimeout 120 -ErrorAction Stop
        }

        catch{

                Write-Output "Error connecting to db server.  Ensure that you have perms on the MSDN Reporting SG."
                $_.Exception.message
                $exitcode=1
                $host.SetShouldExit($exitcode) 
                exit
            
        }
        

        if(!$queryresults){
            Write-Debug "Asset ID $($m) not found."; $url="BUGBUG!"+$m
            Write-Debug "...in $($fileobj.name)"
        }

        if($queryresults.count -gt 1){$queryresults=$queryresults | Select-Object -Last 1; Write-Debug "Multiple results for link to $($m), picked last one"}

        if(!$url){

            $contentid=$queryresults.contentid
            $preferredLib=$queryresults.PreferredLib
            $url='(https://msdn.microsoft.com' + $preferredLib + '/' + $contentid + ')'
            $url=$url.toLower()
            
        }

        Write-Debug "Replacing $($m) with $($url)"

        # use replace operator to replace all occurrences of the keyword in the file, then call this function recursively to look for other keywords
        # First wrap each string in parentheses to ensure we only replace entire RIDs.
        $m="\($m\)"
        $url="($url)"
        testmatch($str -replace ($m),$url)

    }

    else { # no more matches in $str
    
        $m="\($m\)"
        $url="($url)"
        $str=$str.substring(0,$str.length-2) # remove last two chars (out-string adds some whitespace) to cause Git to leave file unmodified if we didn't do any replacements
        $str | Out-File $fileobj -Encoding default # write the updated file
    
    }
} 

$files=Get-ChildItem $InputPath -Include *.md -Recurse
$numfiles=$files.count

Write-Output "Replacing A keyword and assetID values with URLs...."
Write-Output "Note: The first time connecting to the database can take several minutes."

foreach ($fileobj in $files) {
  
    Write-Progress -Activity "Processing $numfiles total files" -Status "Processing file $i" -percentComplete ($i / $numfiles*100)

    $file=Get-Content $fileobj | Out-String # load the whole file as a single string
    testmatch($file) # initial invocation of recursive function on this file
    
    $i++
}

"Replacement complete."
Write-Debug "Lookup table was $($ktbl.count) entries, with $($projectsQueried.count) projects queried."
