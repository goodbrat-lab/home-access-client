@echo off
cd /d "%~dp0"
echo Starting wstunnel client via corporate proxy 10.26.254.42:3128 to wss://home.guseynovia.ru:443 ...
wstunnel.exe client -L "udp://51820:localhost:51820?timeout_sec=0" -p http://10.26.254.42:3128 wss://home.guseynovia.ru:443
pause