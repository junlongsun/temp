#!/bin/bash

# 定义参数检查
paras=$@
function checkPara(){
    local p=$1
    for i in $paras; do if [[ $i == $p ]]; then return; fi; done
    false
}

# 设定区域
REGION=ng
checkPara 'au' && REGION=au-syd # Sydney, Australia
checkPara 'uk' && REGION=eu-gb # London, England
checkPara 'de' && REGION=eu-de # Frankfurt, Germany

# 检查 BBR 参数
BBR=false
checkPara 'bbr' && BBR=true

# 安装 kubectl
 curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
 chmod +x ./kubectl
 sudo mv ./kubectl /usr/local/bin/kubectl

# 安装 docker
rpm -Uvh http://ftp.riken.jp/Linux/fedora/epel/6Server/x86_64/epel-release-6-8.noarch.rpm
yum install -y docker-io
service docker start
chkconfig docker on

# 安装 Bluemix CLI 及插件
wget -O Bluemix_CLI_amd64.tar.gz 'https://clis.ng.bluemix.net/download/bluemix-cli/latest/linux64'
tar -zxf Bluemix_CLI_amd64.tar.gz
cd Bluemix_CLI
sudo ./install_bluemix_cli
bluemix config --usage-stats-collect false
ibmcloud plugin install container-service -r Bluemix


# 初始化
ibmcloud login -a https://api.${REGION}.bluemix.net
(echo 1; echo 1) | ibmcloud target --cf
# ibmcloud cs region-set ap-south
ibmcloud cs init
$(ibmcloud cs cluster-config $(ibmcloud cs clusters | grep 'normal' | awk '{print $1}') | grep 'export')
PPW=$(openssl rand -base64 12 | md5sum | head -c12)
SPW=$(openssl rand -base64 12 | md5sum | head -c12)
AKN=del_$(openssl rand -base64 12 | md5sum | head -c5)
AK=$(ibmcloud iam api-key-create $AKN | tail -1 | awk '{print $3}' | base64)

# 尝试清除以前的构建环境
kubectl delete pod build 2>/dev/null
kubectl delete deploy kube ss bbr 2>/dev/null
kubectl delete svc kube ss ss-tcp ss-udp 2>/dev/null
kubectl delete rs -l run=kube | grep 'deleted' --color=never
kubectl delete rs -l run=ss | grep 'deleted' --color=never
kubectl delete rs -l run=bbr | grep 'deleted' --color=never


# 等待 build 容器停止
while ! kubectl get pod build 2>&1 | grep -q "NotFound"
do
    sleep 5
done

# 创建构建环境
cat << _EOF_ > build.yaml
apiVersion: v1
kind: Pod
metadata:
  name: build
spec:
  containers:
  - name: alpine
    image: docker:dind
    command: ["sleep"]
    args: ["1800"]
    securityContext:
      privileged: true
  restartPolicy: Never
_EOF_
kubectl create -f build.yaml
sleep 3
while ! kubectl exec -it build expr 24 '*' 24 2>/dev/null | grep -q "576"
do
    sleep 5
done
IP=$(kubectl exec -it build -- wget -qO- whatismyip.akamai.com)
CONFDIR=$(dirname $KUBECONFIG)
PEM=$(basename $(ls $CONFDIR/*.pem))
kubectl cp $KUBECONFIG build:/root/config
kubectl cp $CONFDIR/$PEM build:/root/"$PEM"
#(echo 'apk add --update curl ca-certificates openssl'; \
#    echo wget -O build.sh 'https://qiita.com/xiguaiyong/private/861ea06d770f1ba07436.md'; \
#   echo sh build.sh "$AKN" "$AK" "$PPW" "$SPW" "$REGION" "$IP" "$BBR" "$PEM") | kubectl exec -it build sh
#yum install -y yum-utils device-mapper-persistent-data lvm2 wget openssl
#yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
#yum install docker-ce -y
dockerd >/dev/null 2>&1 &
sleep 3

# 初始化镜像库
# ibmcloud plugin install container-registry -r Bluemix
ibmcloud cr login
for name in $(ibmcloud cr namespace-list | grep del_); do (echo y) | ibmcloud cr namespace-rm $name; done
NS=del_$(openssl rand -base64 16 | md5sum | head -c16)
ibmcloud cr namespace-add $NS

# 构建 SS 容器
cat << _EOF_ >Dockerfile
FROM easypi/shadowsocks-libev
ENV SERVER_PORT 443
ENV METHOD aes-256-cfb
ENV PASSWORD $SPW
_EOF_
docker build -t registry.${REGION}.bluemix.net/$NS/ss .
while ! ibmcloud cr image-list | grep -q "registry.${REGION}.bluemix.net/$NS/ss"
do
    docker push registry.${REGION}.bluemix.net/$NS/ss
done

# 创建 BBR 构建文件
cat << _EOF_ > bbr.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  labels:
    app: bbr 
  name: bbr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bbr
  template:
    metadata:
      labels:
        app: bbr
      name: bbr
    spec:
      containers:
      - env:
        - name: TARGET_HOST
          value: SS_IP
        - name: TARGET_PORT
          value: "443"
        - name: BIND_PORT
          value: "443"
        image: wuqz/lkl:latest
        name: bbr
        securityContext:
          privileged: true
      restartPolicy: Always
_EOF_

# 创建 SS 运行环境
kubectl run ss --image=registry.${REGION}.bluemix.net/$NS/ss --port=443
if $BBR; then
    kubectl expose deployment ss --name=ss
    sed -i "s/SS_IP/$(kubectl get svc ss -o=custom-columns=IP:.spec.clusterIP | tail -n1)/g" bbr.yaml
    kubectl create -f bbr.yaml
    kubectl expose deployment bbr --type=LoadBalancer --port=443 --name=ss-tcp --external-ip $IP
else
    kubectl expose deployment ss --type=LoadBalancer --name=ss-tcp --external-ip $IP
fi
kubectl expose deployment ss --type=LoadBalancer --name=ss-udp --external-ip $IP --protocol="UDP"

# 删除构建环境
kubectl delete pod build

# 输出信息
#PP=$(kubectl get svc kube -o=custom-columns=Port:.spec.ports\[\*\].nodePort | tail -n1)
#SP=$(kubectl get svc ss -o=custom-columns=Port:.spec.ports\[\*\].nodePort | tail -n1)
SP=443
#IP=$(kubectl get node -o=custom-columns=Port:.metadata.name | tail -n1)
wget https://coding.net/u/tprss/p/bluemix-source/git/raw/master/v2/cowsay
chmod +x cowsay
cat << _EOF_ > default.cow
\$the_cow = <<"EOC";
        \$thoughts   ^__^
         \$thoughts  (\$eyes)\\\\_______
            (__)\\       )\\\\/\\\\
             \$tongue ||----w |
                ||     ||
EOC
_EOF_
clear
echo 是不是很惊不惊喜，意不意外？
# echo ' 管理面板地址: ' http://$IP/$PPW/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
echo 
echo ' SS:'
echo '  IP: '$IP
echo '  Port: '$SP
echo '  Password: '$SPW
echo '  Method: aes-256-cfb'
ADDR='ss://'$(echo -n "aes-256-cfb:$SPW@$IP:$SP" | base64)
echo 
echo '  快速添加: '$ADDR
echo '  二维码: http://qr.liantu.com/api.php?text='$ADDR
echo 