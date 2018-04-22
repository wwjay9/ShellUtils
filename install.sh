#!/bin/bash

# jdkRpm的下载链接
jdkRpmDownloadUrl="http://download.oracle.com/otn-pub/java/jdk/8u171-b11/512cd62ec5174c3487ac17c61aaa89e8/jdk-8u171-linux-x64.rpm"

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
    systemctl start $1
    systemctl enable $1
    systemctl status $1

    if pgrep $1 > /dev/null; then
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
        firewall-cmd --permanent --zone=public --add-port=${port}/tcp
    done
    firewall-cmd --reload
}


echoOk "你的系统版本信息为:\n$(cat /etc/system-release)"

###
## 修改yum安装源为aliyun
###
yum repolist | grep mirrors.aliyun.com > /dev/null
if [ $? != 0 ]; then
    echoOk "修改yum安装源为aliyun"
    # 查看当前的yum源配置
    yum repolist
    # 备份当前的yum源配置
    mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
    # 下载aliyun配置
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
fi
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
yum install yum-utils wget lrzsz gcc make vim -y

###
## 解决在ECS或docker中系统熵过低的问题
###
entropy=$(cat /proc/sys/kernel/random/entropy_avail)
if (($entropy < 1000));then
    echoOk "当前系统熵值为:$entropy,需要安装haveged伪随机数生成器"
    mkdir /usr/local/haveged
    cd /usr/local/haveged
    wget http://www.issihosts.com/haveged/haveged-1.9.1.tar.gz
    tar -zxv -f haveged-*.tar.gz --strip-components=1
    ./configure
    make
    make install

    # 创建service文件
    cat > /etc/systemd/system/haveged.service << EOF
[Unit]
Description=haveged server

[Service]
Type=forking

ExecStart=/usr/local/sbin/haveged

[Install]
WantedBy=multi-user.target
EOF

    testRun haveged
fi

###Unresolved variable
## 安装jdk
###
echoOk "安装jdk"
wget --no-check-certificate -c --header "Cookie: oraclelicense=accept-securebackup-cookie" ${jdkRpmDownloadUrl}
yum localinstall jdk-*.rpm -y
if java -version; then
    echoOk "jdk安装成功"
else
    echoErr "=========================jdk安装出错========================="
    exit 1
fi
rm jdk-*.rpm -f
cat >> /etc/profile << EOF

JAVA_HOME=/usr/java/latest
export JAVA_HOME
EOF
source /etc/profile

###
## 安装MySql
###
echoOk "安装MySql"
yum list installed | grep mariadb && yum remove mariadb* -y
yum localinstall https://repo.mysql.com/mysql57-community-release-el7-11.noarch.rpm -y
yum install mysql-community-server -y
testRun mysqld
passwordLog=$(grep 'temporary password' /var/log/mysqld.log)
tempPassword="${passwordLog: -12}"
mysql -uroot -p${tempPassword} --connect-expired-password <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'q6IzZ|AX<@l}';
uninstall plugin validate_password;
ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';
EOF
#mysql -uroot -p${tempPassword} --connect-expired-password -Bse "ALTER USER 'root'@'localhost' IDENTIFIED BY 'q6IzZ|AX<@l}';uninstall plugin validate_password;ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';"
openPort 3306

###
## 安装Redis
###
echoOk "安装Redis"
mkdir /usr/local/redis
cd /usr/local/redis/
wget http://download.redis.io/releases/redis-4.0.9.tar.gz
tar -zxv -f redis-*.tar.gz --strip-components=1
make
make install
mkdir /etc/redis
mkdir /var/redis
cp /usr/local/redis/redis.conf /etc/redis/
cat >> /etc/sysctl.conf << EOF

#设置内核内存过量使用为true
vm.overcommit_memory = 1
#修改 backlog 连接数的最大值超过 redis.conf 中的 tcp-backlog 值，即默认值511
net.core.somaxconn = 511
EOF
sysctl -p
# 开启透明巨页内存支持（创建自定义系统服务）
mkdir /root/script
cat > /root/script/autostart.sh << EOF
#!/bin/bash
# Program:
# 自动启动脚本

# 开启透明巨页内存支持
echo never > /sys/kernel/mm/transparent_hugepage/enabled
EOF
chmod +x /root/script/autostart.sh
cat > /etc/systemd/system/autostart-script.service << EOF
[Unit]
Description=Autostart script

[Service]
Type=oneshot

ExecStart=/root/script/autostart.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start autostart-script
systemctl enable autostart-script
# 修改配置文件
sed -i -e 's/daemonize no/daemonize yes/g' /etc/redis/redis.conf
sed -i -e 's/logfile ""/logfile \/var\/log\/redis.log/g' /etc/redis/redis.conf
sed -i -e 's/dir \.\//dir  \/var\/redis\//g' /etc/redis/redis.conf
cat > /etc/systemd/system/redis.service << EOF
[Unit]
Description=Run redis server

[Service]
Type=forking

ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown

[Install]
WantedBy=multi-user.target
EOF
testRun redis
openPort 6379

###
## 安装Docker
###
echoOk "安装Docker"
yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine -y
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum makecache fast
yum install docker-ce -y
usermod -a -G docker ${USER}
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
yum localinstall https://dl.bintray.com/rabbitmq/rpm/erlang/20/el/7/x86_64/erlang-20.3.4-1.el7.centos.x86_64.rpm -y
yum localinstall https://dl.bintray.com/rabbitmq/all/rabbitmq-server/3.7.4/rabbitmq-server-3.7.4-1.el7.noarch.rpm -y
chkconfig rabbitmq-server on
# TODO 无法测试rabbitmq-server是否运行
#testRun rabbitmq-server
systemctl start rabbitmq-server
rabbitmq-plugins enable rabbitmq_management
# 创建一个新用户来登录web管理页面
rabbitmqctl add_user admin admin
rabbitmqctl set_user_tags admin administrator
rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
openPort 15672 5671 5672

###
## 安装nginx
###
echoOk "安装nginx"
cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/7/\$basearch/
gpgcheck=0
enabled=1
EOF
yum install nginx -y
testRun nginx
# 解决nginx代理本地服务时出现的13: Permission denied问题
setsebool httpd_can_network_connect true -P
openPort 80

echoOk "所有软件已安装完成"
