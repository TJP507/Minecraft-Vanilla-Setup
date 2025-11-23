# Minecraft-Setup

### This script has been validate for Ubuntu 24.04.3 (Noble)

To check your build version, execute `lsb_release -a`

<img width="377" height="133" alt="image" src="https://github.com/user-attachments/assets/e1d4d33b-23c5-411d-b636-7a5339a11c3a" />


`cd ~`

`wget https://raw.githubusercontent.com/TJP507/Minecraft-Vanilla-Setup/refs/heads/main/Minecraft-Vanilla-Server-Setup.sh`

`sudo chmod +x ./Minecraft-Vanilla-Server-Setup.sh`

`sudo ./Minecraft-Vanilla-Server-Setup.sh`

Follow the prompts to configure the Minecraft server.




IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
echo "$IP"
