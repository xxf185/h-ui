#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

init_var() {
  ECHO_TYPE="echo -e"

  package_manager=""
  release=""
  version=""
  get_arch=""

  HUI_DATA_DOCKER="/h-ui/"
  HUI_DATA_SYSTEMD="/usr/local/h-ui/"

  h_ui_port=8081
  h_ui_time_zone=Asia/Shanghai
}

echo_content() {
  case $1 in
  "red")
    ${ECHO_TYPE} "\033[31m$2\033[0m"
    ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m"
    ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m"
    ;;
  "blue")
    ${ECHO_TYPE} "\033[34m$2\033[0m"
    ;;
  "purple")
    ${ECHO_TYPE} "\033[35m$2\033[0m"
    ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m"
    ;;
  "white")
    ${ECHO_TYPE} "\033[37m$2\033[0m"
    ;;
  esac
}

can_connect() {
  if ping -c2 -i0.3 -W1 "$1" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "必须以root用户运行该脚本"
    exit 1
  fi

  can_connect www.google.com
  if [[ "$?" == "1" ]]; then
    echo_content red "---> 网络连接失败"
    exit 1
  fi

  if [[ $(command -v yum) ]]; then
    package_manager='yum'
  elif [[ $(command -v dnf) ]]; then
    package_manager='dnf'
  elif [[ $(command -v apt-get) ]]; then
    package_manager='apt-get'
  elif [[ $(command -v apt) ]]; then
    package_manager='apt'
  fi

  if [[ -z "${package_manager}" ]]; then
    echo_content red "目前不支持此系统"
    exit 1
  fi

  if [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    version=$(rpm -q --queryformat '%{VERSION}' centos-release)
  elif grep </etc/issue -q -i "debian" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "debian" && [[ -f "/proc/version" ]]; then
    release="debian"
    version=$(cat /etc/debian_version)
  elif grep </etc/issue -q -i "ubuntu" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "ubuntu" && [[ -f "/proc/version" ]]; then
    release="ubuntu"
    version=$(lsb_release -sr)
  fi

  major_version=$(echo "${version}" | cut -d. -f1)

  case $release in
  centos)
    if [[ $major_version -ge 6 ]]; then
      echo_content green "检测到支持的CentOS版本:$version"
    else
      echo_content red "不受支持的CentOS版本:$version. 仅支持CentOS 6+."
      exit 1
    fi
    ;;
  ubuntu)
    if [[ $major_version -ge 16 ]]; then
      echo_content green "检测到支持的Ubuntu版本:$version"
    else
      echo_content red "不支持的Ubuntu版本:$version.仅支持Ubuntu 16+."
      exit 1
    fi
    ;;
  debian)
    if [[ $major_version -ge 8 ]]; then
      echo_content green "检测到支持的Debian版本:$version"
    else
      echo_content red "不支持的Debian版本:$version.仅支持Debian 8+."
      exit 1
    fi
    ;;
  *)
    echo_content red "仅支持CentOS 6+/Ubuntu 16+/Debian 8+"
    exit 1
    ;;
  esac

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "仅支持 x86_64/amd64 arm64/aarch64"
    exit 1
  fi
}

install_depend() {
  if [[ "${package_manager}" == 'apt-get' || "${package_manager}" == 'apt' ]]; then
    ${package_manager} update -y
  fi
  ${package_manager} install -y \
    curl \
    systemd \
    nftables
}

setup_docker() {
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  }
}
EOF
  systemctl daemon-reload
}

remove_forward(){
  if command -v nft &> /dev/null && nft list tables | grep -q hui_porthopping; then
    nft delete table inet hui_porthopping
  fi
  if command -v iptables &> /dev/null;then
    for num in $(iptables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      iptables -t nat -D PREROUTING $num
    done
  fi
  if command -v ip6tables &> /dev/null;then
    for num in $(ip6tables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      ip6tables -t nat -D PREROUTING $num
    done
  fi
}

install_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content green "---> 安装Docker"

    bash <(curl -fsSL https://get.docker.com)

    setup_docker

    systemctl enable docker && systemctl restart docker

    if [[ $(command -v docker) ]]; then
      echo_content skyBlue "---> Docker安装成功"
    else
      echo_content red "---> Docker安装失败"
      exit 1
    fi
  else
    echo_content skyBlue "---> Docker已安装"
  fi
}

install_h_ui_docker() {
  if [[ -n $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content skyBlue "---> H-UI已安装"
    exit 0
  fi

  echo_content green "---> 安装H-UI"
  mkdir -p ${HUI_DATA_DOCKER}

  read -r -p "请输入H-UI的端口(默认:8081):" h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "请输入H-UI的时区(默认:Asia/Shanghai):" h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  docker pull jonssonyan/h-ui &&
    docker run -d --cap-add=NET_ADMIN \
      --name h-ui --restart always \
      --network=host \
      -e TZ=${h_ui_time_zone} \
      -v /h-ui/bin:/h-ui/bin \
      -v /h-ui/data:/h-ui/data \
      -v /h-ui/export:/h-ui/export \
      -v /h-ui/logs:/h-ui/logs \
      jonssonyan/h-ui \
      ./h-ui -p ${h_ui_port}
  echo_content skyBlue "---> H-UI安装成功"
}

upgrade_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker未安装"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> H-UI未安装"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/xxf185/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H-UI已经是最新版本"
    exit 0
  fi

  echo_content green "---> 升级H-UI"
  docker rm -f h-ui
  docker rmi jonssonyan/h-ui
  install_h_ui_docker
  echo_content skyBlue "---> H-UI升级成功"
}

uninstall_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker未安装"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> H-UI未安装"
    exit 0
  fi

  echo_content green "---> 卸载H-UI"
  docker rm -f h-ui
  docker rmi jonssonyan/h-ui
  rm -rf /h-ui/
  remove_forward
  echo_content skyBlue "---> H-UI卸载成功"
}

install_h_ui_systemd() {
  if systemctl status h-ui &>/dev/null; then
    echo_content skyBlue "---> H-UI已安装"
    exit 0
  fi

  echo_content green "---> 安装H-UI"
  mkdir -p ${HUI_DATA_SYSTEMD}

  read -r -p "请输入H-UI端口(默认:8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "请输入H-UI的时区(默认:Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  timedatectl set-timezone ${h_ui_time_zone} && timedatectl set-local-rtc 0
  systemctl restart rsyslog
  if [[ "${release}" == "centos" ]]; then
    systemctl restart crond
  elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
    systemctl restart cron
  fi

  export GIN_MODE=release
  curl -fsSL https://github.com/xxf185/h-ui/releases/latest/download/h-ui-linux-${get_arch} -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    curl -fsSL https://raw.githubusercontent.com/xxf185/h-ui/master/h-ui.service -o /etc/systemd/system/h-ui.service &&
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/h-ui/h-ui -p ${h_ui_port}|" "/etc/systemd/system/h-ui.service" &&
    systemctl daemon-reload &&
    systemctl enable h-ui &&
    systemctl restart h-ui
  echo_content skyBlue "---> H-UI安装成功"
}

upgrade_h_ui_systemd() {
  if ! systemctl status h-ui &>/dev/null; then
    echo_content red "---> H-UI未安装"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/xxf185/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H-UI已是最新版本"
    exit 0
  fi

  echo_content green "---> 升级H-UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  curl -fsSL https://github.com/xxf185/h-ui/releases/latest/download/h-ui-linux-${get_arch} -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    systemctl restart h-ui
  echo_content skyBlue "---> H-UI升级成功"
}

uninstall_h_ui_systemd() {
  if ! systemctl status h-ui &>/dev/null; then
    echo_content red "---> H-UI未安装"
    exit 0
  fi

  echo_content green "---> 卸载H-UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  systemctl disable h-ui.service &&
    rm -f /etc/systemd/system/h-ui.service &&
    systemctl daemon-reload &&
    rm -rf /usr/local/h-ui/
  remove_forward
  echo_content skyBlue "---> H-UI卸载完成"
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  clear
  echo_content red "\n"
  echo_content yellow "\n----------H-UI----------"
  echo_content red "\n"
  echo_content yellow "1. 安装H-UI(Docker)"
  echo_content yellow "2. 升级H-UI(Docker)"
  echo_content yellow "3. 卸载H-UI(Docker)"
  echo_content yellow "4. 安装H-UI(systemd)"
  echo_content yellow "5. 升级H-UI(systemd)"
  echo_content yellow "6. 卸载H-UI(systemd)"
  echo_content red "\n"
  read -r -p "选项: " input_option
  case ${input_option} in
  1)
    install_docker
    install_h_ui_docker
    ;;
  2)
    upgrade_h_ui_docker
    ;;
  3)
    uninstall_h_ui_docker
    ;;
  4)
    install_h_ui_systemd
    ;;
  5)
    upgrade_h_ui_systemd
    ;;
  6)
    uninstall_h_ui_systemd
    ;;
  *)
    echo_content red "No such option"
    ;;
  esac
}

main