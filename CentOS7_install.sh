#!/bin/bash

# 输出普通信息
echoOk(){
    echo -e "\033[36m$1\033[0m"
}

# 输出错误信息
echoErr(){
    echo -e "\033[41m$1\033[0m"
}

# 将指定的服务启动并测试程序是否在运行,如果没有在运行则退出脚本
testRun(){
    systemctl daemon-reload
    systemctl start "$1"
    systemctl enable "$1"
    systemctl status "$1"

    if pgrep "$1" > /dev/null; then
        echoOk "$1安装完成"
    else
        echoErr "=========================$1安装出错========================="
        exit 1
    fi
}

# 打开防火墙端口
openPort(){
    for port in "$@"
    do
        firewall-cmd --permanent --zone=public --add-port="${port}"/tcp
    done
    firewall-cmd --reload
}


echoOk "你的系统版本信息为:\n$(cat /etc/system-release)"

###
## 添加yum源
###
echoOk "添加yum源"
# 查看当前的yum源配置
yum repolist
# 替换CentOS镜像
sed -e 's!^mirrorlist=!#mirrorlist=!g' \
    -e 's!^#baseurl=!baseurl=!g' \
    -e 's!http[s]*://mirror.centos.org/centos!https://mirrors.aliyun.com/centos!g' \
    -i /etc/yum.repos.d/CentOS-Base.repo
# 添加epel.repo
cat > /etc/yum.repos.d/epel.repo << EOF
[epel]
name=Extra Packages for Enterprise Linux 7 - \$basearch
baseurl=https://mirrors.aliyun.com/epel/7/\$basearch/
enabled=1
gpgcheck=0
EOF
# 添加ius.repo
cat > /etc/yum.repos.d/ius.repo << EOF
[ius]
name=IUS for Enterprise Linux 7 - \$basearch
baseurl=https://mirrors.aliyun.com/ius/7/\$basearch/
enabled=1
gpgcheck=0
EOF
# 添加remi.repo
cat > /etc/yum.repos.d/remi.repo << EOF
[remi]
name=Remi RPM repository for Enterprise Linux 7 - \$basearch
baseurl=https://mirrors.aliyun.com/remi/enterprise/7/remi/\$basearch/
enabled=1
gpgcheck=0
EOF
# 清理缓存
yum clean all
# 重新建立缓存
yum makecache

###
## 升级系统
###
echoOk "升级系统"
yum update -y

###
## 设置语言环境为中文
###
echoOk "设置语言环境为中文"
localectl set-locale LANG=zh_CN.utf8

###
## 修改时区为中国上海时区
###
echoOk "修改时区为中国上海时区"
timedatectl set-timezone Asia/Shanghai

###
## 安装ntp
###
echoOk "安装ntp"
yum install ntp -y
chkconfig ntpd on
ntpdate pool.ntp.org
testRun ntpd

###
## 安装常用工具
###
echoOk "安装常用工具"
yum install yum-utils wget lrzsz vim git224 zip unzip -y

###
## 解决在ECS或docker中系统熵过低的问题
###
entropy=$(cat /proc/sys/kernel/random/entropy_avail)
if (($entropy < 1000));then
    echoOk "当前系统熵值为:$entropy,需要安装haveged伪随机数生成器"
    yum install haveged -y
    testRun haveged
fi

###
## 安装jdk
###
echoOk "安装jdk"
yum install java-11-openjdk-devel -y
if java -version; then
    echoOk "jdk安装成功"
else
    echoErr "=========================jdk安装出错========================="
    exit 1
fi
tee /etc/environment -a <<-'EOF'
JAVA_HOME=/etc/alternatives/java_sdk
EOF
source /etc/environment

###
## 安装MySql,安装后的root密码为123456
###
echoOk "安装MySql"
yum list installed | grep mariadb && yum remove mariadb* -y
yum localinstall https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm -y
sed -e 's!^baseurl=http[s]*://repo.mysql.com!baseurl=https://mirrors.ustc.edu.cn/mysql-repo!g' \
    -i /etc/yum.repos.d/mysql-community.repo /etc/yum.repos.d/mysql-community-source.repo
yum install mysql-community-server -y
testRun mysqld
passwordLog=$(grep 'temporary password' /var/log/mysqld.log)
tempPassword="${passwordLog: -12}"
# 修改密码、删除匿名用户、禁止root远程访问、删除测试数据库
mysql -uroot -p"${tempPassword}" --connect-expired-password <<EOF
SET GLOBAL validate_password.policy = 0;
SET GLOBAL validate_password.length = 0;
ALTER USER 'root'@'localhost' IDENTIFIED BY '123456';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
openPort 3306

###
## 安装Redis
###
echoOk "安装Redis"
yum install redis -y
testRun redis
openPort 6379

###
## 安装Docker
###
echoOk "安装Docker"
yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine -y
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum install docker-ce -y
usermod -a -G docker "${USER}"
mkdir -p /etc/docker
tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["https://jud69dgu.mirror.aliyuncs.com"]
}
EOF
testRun docker

###
## 安装RabbitMQ
###
echoOk "安装RabbitMQ"
yum localinstall https://packagecloud.io/rabbitmq/erlang/packages/el/7/erlang-23.0.4-1.el7.x86_64.rpm/download.rpm -y
yum localinstall https://packagecloud.io/rabbitmq/rabbitmq-server/packages/el/7/rabbitmq-server-3.8.8-1.el7.noarch.rpm/download.rpm -y
chkconfig rabbitmq-server on
systemctl start rabbitmq-server
rabbitmq-plugins enable rabbitmq_management
# 创建一个新用户来登录web管理页面
rabbitmqctl add_user admin admin
rabbitmqctl set_user_tags admin administrator
rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
openPort 15672 5671 5672

###
## 安装Nginx
###
echoOk "安装Nginx"
cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=https://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=0
enabled=1
EOF
yum install nginx -y
testRun nginx
# 解决nginx代理本地服务时出现的13: Permission denied问题
setsebool httpd_can_network_connect true -P
openPort 80

###
## 安装MongoDB
###
echoOk "安装MongoDB"
cat > /etc/yum.repos.d/mongodb-org-4.2.repo << EOF
[mongodb-org-4.2]
name=MongoDB Repository
baseurl=https://mirrors.aliyun.com/mongodb/yum/redhat/\$releasever/mongodb-org/4.2/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.2.asc
EOF
yum install mongodb-org -y
testRun mongod

###
## 安装NodeJS
###
echoOk "安装NodeJS"
curl -sL https://rpm.nodesource.com/setup_14.x | sudo bash -
sed -e 's!http[s]*://rpm.nodesource.com!https://mirrors.ustc.edu.cn/nodesource/rpm!g' \
    -i /etc/yum.repos.d/nodesource-*.repo
yum install nodejs -y
if node -v && npm -v; then
    echoOk "NodeJS安装成功"
else
    echoErr "=========================NodeJS安装出错========================="
    exit 1
fi
npm config set registry https://registry.npm.taobao.org
npm config get registry

echoOk "所有软件已安装完成"
# 关闭防火墙
systemctl stop firewalld
systemctl disable firewalld
echoOk "防火墙已关闭"
