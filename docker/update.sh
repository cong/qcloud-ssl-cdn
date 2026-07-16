#!/bin/sh

set -u

# 函数：检查证书是否有效
check_cert_valid() {
  local domain="$1"
  local cert_dir="${CERT_HOME}/${domain}"
  local cert_file="${cert_dir}/fullchain.cer"
  
  # 1. 检查证书文件是否存在
  if [ ! -f "${cert_file}" ]; then
    echo "📋 证书文件 ${cert_file} 不存在，需要重新申请"
    return 1
  fi
  
  # 2. 检查证书是否包含当前域名
  if ! openssl x509 -in "${cert_file}" -noout -text 2>/dev/null | grep -q "CN.*${domain}"; then
    echo "📋 证书中的域名与当前域名 ${domain} 不匹配，需要重新申请"
    return 1
  fi
  
  # 3. 检查证书是否过期
  local current_epoch=$(date -u +%s)
  local cert_expiry=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
  
  if [ -z "${cert_expiry}" ]; then
    echo "📋 无法解析证书过期时间，视为无效"
    return 1
  fi
  
  # 尝试转换日期格式（兼容不同系统）
  local cert_expiry_epoch=$(date -d "${cert_expiry}" -u +%s 2>/dev/null)
  if [ -z "${cert_expiry_epoch}" ] || [ "${cert_expiry_epoch}" -eq 0 ]; then
    # 如果上面的命令失败，尝试另一种格式
    cert_expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "${cert_expiry}" +%s 2>/dev/null)
    if [ -z "${cert_expiry_epoch}" ] || [ "${cert_expiry_epoch}" -eq 0 ]; then
      echo "📋 无法解析证书过期时间（格式: ${cert_expiry}），视为无效"
      return 1
    fi
  fi
  
  # 计算剩余天数
  local days_left=$(( (cert_expiry_epoch - current_epoch) / 86400 ))
  echo "📅 证书剩余有效天数: ${days_left} 天"
  
  # 如果剩余天数小于30天，建议重新申请
  if [ ${days_left} -lt 30 ]; then
    echo "📋 证书剩余天数少于30天，将重新申请"
    return 1
  fi
  
  echo "✅ 证书有效，剩余 ${days_left} 天，将复用现有证书"
  return 0
}

# 检查是否启用ACME，并决定是否申请证书
if [ "${ACME_ENABLED:=true}" = "true" ]; then
  # 先检查证书是否已存在且有效
  if check_cert_valid "${ACME_DOMAIN}"; then
    echo "📌 跳过证书申请步骤，使用现有证书"
  else
    echo "🔄 开始申请/更新证书..."
    # 使用acme获取/更新证书
    ${ACME_HOME}/acme.sh ${ACME_PARAMS:-} --force --issue --cert-home ${CERT_HOME} -d ${ACME_DOMAIN} -d *.${ACME_DOMAIN} --dns ${ACME_DNS_TYPE}
    
    # 检查申请是否成功
    if [ $? -ne 0 ]; then
      echo "❌ 证书申请失败，请检查日志"
      exit 1
    fi
    echo "✅ 证书申请完成"
  fi
  
  # 兼容ecc证书处理
  ECC_CERT_FOUND="false"
  if [ -d "${CERT_HOME}/${ACME_DOMAIN}_ecc" ]; then
    echo "检测到 ECC 证书目录，正在复制到 ${CERT_HOME}/${ACME_DOMAIN}"
    mkdir -p ${CERT_HOME}/${ACME_DOMAIN}
    # 添加 -v 参数显示复制过程，便于调试
    cp -rvf ${CERT_HOME}/${ACME_DOMAIN}_ecc/* ${CERT_HOME}/${ACME_DOMAIN}
    # 检查复制结果 - 重点检查证书文件是否存在
    if [ $? -eq 0 ] && [ -f "${CERT_HOME}/${ACME_DOMAIN}/fullchain.cer" ] && [ -f "${CERT_HOME}/${ACME_DOMAIN}/${ACME_DOMAIN}.key" ]; then
      echo "✅ ECC 证书复制成功"
    else
      echo "⚠️ ECC 证书复制后，标准目录中证书文件不完整，尝试直接使用 _ecc 路径"
      # 检查 _ecc 目录中是否有证书文件
      if [ -f "${CERT_HOME}/${ACME_DOMAIN}_ecc/fullchain.cer" ] && [ -f "${CERT_HOME}/${ACME_DOMAIN}_ecc/${ACME_DOMAIN}.key" ]; then
        echo "💡 将在后续步骤中直接使用 ECC 证书路径"
        ECC_CERT_FOUND="true"
      else
        echo "❌ 错误：在 ECC 目录中未找到完整的证书文件"
        echo "📂 请检查 ${CERT_HOME}/${ACME_DOMAIN}_ecc/ 目录内容："
        ls -la ${CERT_HOME}/${ACME_DOMAIN}_ecc/ 2>/dev/null || echo "目录不存在"
        exit 1
      fi
    fi
  else
    echo "未检测到 ECC 证书目录，检查标准证书目录"
    # 如果标准目录也不存在，直接报错退出
    if [ ! -f "${CERT_HOME}/${ACME_DOMAIN}/fullchain.cer" ]; then
      echo "❌ 错误：在 ${CERT_HOME}/${ACME_DOMAIN} 未找到证书文件"
      echo "📂 请检查 ${CERT_HOME}/${ACME_DOMAIN}/ 目录内容："
      ls -la ${CERT_HOME}/${ACME_DOMAIN}/ 2>/dev/null || echo "目录不存在"
      exit 1
    fi
    echo "✅ 标准证书文件存在"
  fi
fi

# 添加刷新url
echo "${PUSH_URLS:-}" | tr ',' '\n' > ${WORK_DIR}/urls.txt
if [ -n "${PUSH_URLS_PATH:-}" ]; then
  cat "${PUSH_URLS_PATH}" >> ${WORK_DIR}/urls.txt
fi

# 写入腾讯云cdn更新配置
cat>${WORK_DIR}/config.py<<-EOF
#!/usr/bin/env python
# -*- coding: utf-8 -*-
# author: 'zfb'
# time: 2020-12-02 16:15

# 腾讯云支持使用单域名和泛域名的证书，例如
# acme.sh --issue  -d "whuzfb.cn" -d "*.whuzfb.cn" --dns dns_dp
# acme.sh --issue  -d "blog.whuzfb.cn" --dns dns_dp

# 使用ACME申请的SSL完整证书的本地存放路径
$( [ "${ECC_CERT_FOUND}" = "true" ] && echo "CER_FILE = \"${CERT_HOME}/${ACME_DOMAIN}_ecc/fullchain.cer\"" || echo "CER_FILE = \"${CERT_HOME}/${ACME_DOMAIN}/fullchain.cer\"" )

# 使用ACME申请的SSL证书私钥的本地存放路径
$( [ "${ECC_CERT_FOUND}" = "true" ] && echo "KEY_FILE = \"${CERT_HOME}/${ACME_DOMAIN}_ecc/${ACME_DOMAIN}.key\"" || echo "KEY_FILE = \"${CERT_HOME}/${ACME_DOMAIN}/${ACME_DOMAIN}.key\"" )

# CDN服务配置的域名（需要提前在腾讯云网页前端创建）
# 如果ACME申请的证书为泛域名证书，且要配置多个CDN加速
# CDN_DOMAIN = ["blog.whuzfb.cn", "blog2.whuzfb.cn", "web.whuzfb.cn"]
CDN_DOMAIN = ["`echo ${CDN_DOMAIN} | sed -e 's/,/","/g'`"]

# 腾讯云：https://console.cloud.tencent.com/cam/capi
SECRETID = "${SECRETID}"
SECRETKEY = "${SECRETKEY}"

# 控制功能开关
# 是否进行上传证书文件的操作（根据CER_FILE和KEY_FILE）
UPLOAD_SSL = ${UPLOAD_SSL:-True}
# 以下为HTTPS额外功能
# 是否开启HTTP2
ENABLE_HTTP2 = ${ENABLE_HTTP2:-True}
# 是否开启HSTS
ENABLE_HSTS = ${ENABLE_HSTS:-True}
# 为HSTS设定最长过期时间（以秒为单位）
HSTS_TIMEOUT_AGE = ${HSTS_TIMEOUT_AGE:-15552000}
# HSTS包含子域名（仅对泛域名有效）
HSTS_INCLUDE_SUBDOMAIN = ${HSTS_INCLUDE_SUBDOMAIN:-True}
# 是否开启OCSP
ENABLE_OCSP = ${ENABLE_OCSP:-True}
# 是否删除适用于CDN_DOMAIN域名下的其他所有证书
# 满足以下条件：证书适用于CDN_DOMAIN、证书id不是本次使用的id
DELETE_OLD_CERTS = ${DELETE_OLD_CERTS:-True}

# 是否进行为CDN_DOMAIN更换SSL证书的操作
# 若UPDATE_SSL = True且UPLOAD_SSL = True，则CERT_ID可不设置，直接利用UPLOAD_SSL的证书
UPDATE_SSL = ${UPDATE_SSL:-True}

# 是否为腾讯云直播域名更换SSL证书的操作
# 若UPDATE_LIVE_SSL = True 注意请将UPDATE_SSL、ENABLE_HSTS、ENABLE_OCSP、ENABLE_HTTP2 设置为 False
UPDATE_LIVE_SSL = ${UPDATE_LIVE_SSL:-False}

CERT_ID = ""
# 是否进行预热URL的操作
PUSH_URL = ${PUSH_URL:-True}
# 是否进行刷新URL的操作
PURGE_URL = ${PURGE_URL:-True}
# 自定义的预热URL（默认会预热sitemap.xml的所有链接）文件路径
# 该文件内，每行一个URL，例如
# https://blog.whuzfb.cn/img/me2.jpg
# https://blog.whuzfb.cn/img/home-bg.jpg
URLS_FILE = "urls.txt"
# 仅用于边缘安全加速平台EO更换SSL证书，不用于CDN
# 区域ID：可以手动利用函数get_teo_zones_list获取所有的加速区域ID；格式为 zone-xxxxxx
ZONE_ID = "${ZONE_ID:-}"
EOF

# 更新CDN证书
cd ${WORK_DIR} && python main.py
