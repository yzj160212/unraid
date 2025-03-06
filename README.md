# unraid自用一键脚本
- 本人使用的 NAS 是 unraid 系统，因 NAS 里部署的容器较多（目前大概 70 多个容器，没办法好玩的项目太多了，后续可能还会缓慢增加），而使用 unraid 系统自带的 docker 管理工具部署容器多了以后就发现一个问题，unraid 后台管理页面打开卡顿，半天刷新不出来。原以为是浏览器缓存或者其他什么原因导致的。后来发现是使用 unraid 系统的 docker 和 docker compose 插件，以及 docker 图标的原因。于是乎，不再使用 unraid 的 docker 和 docker compose 插件，直接命令行部署，此脚本也只适用于在 unraid 系统 /mnt/cache/appdata/xxx 目录下的 docker-compose.yml 部署的容器。。。懂得都懂，不再废话🐒
### 使用说明
- 每个脚本都有简介，自行查看了解，不再赘述。脚本可以直接复制粘贴到你的 unraid 脚本插件（User Scripts）里去使用。

- 一键安装Docker Compose
```
wget https://raw.githubusercontent.com/yzj160212/unraid/main/install-docker-compose.sh -O install-docker-compose.sh && chmod +x install-docker-compose.sh && sudo ./install-docker-compose.sh
```

- 一键启动所有docker容器
```
wget https://raw.githubusercontent.com/yzj160212/unraid/main/manage-containers.sh -O manage-containers.sh && chmod +x manage-containers.sh && ./manage-containers.sh
```

- 一键停止所有docker容器
```
wget https://raw.githubusercontent.com/yzj160212/unraid/main/stop-containers.sh -O stop-containers.sh && chmod +x stop-containers.sh && ./stop-containers.sh
```

- 一键恢复所有docker容器
```
wget https://raw.githubusercontent.com/yzj160212/unraid/main/restore-containers.sh -O restore-containers.sh && chmod +x restore-containers.sh && ./restore-containers.sh
```