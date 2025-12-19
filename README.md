<h1 align="center">OTA EPG Enhancer</h1>

For use with Jellyfin/Tvheadend

Retrieves raw OTA EPG Data from Tvheadend then enhances it with TVMaze and TMDB

Usage:

   1) Create a username/password in TVheadend, add them to the top of the script
   2) Get a free TMDB API key, add it to the top of the script
   3) Set cache folder and output file locations at top of script
   
The final output should be added to Jellyfin as an XMLTV guide source, this script can be run as a scheduled task, and will keep a cache file to avoid redundant workloads.