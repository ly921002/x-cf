# 使用轻量级的 Alpine Linux 作为基础镜像
FROM alpine:latest

# 设置工作目录
WORKDIR /app

# 安装必要的依赖包
RUN apk add --no-cache \
    curl \
    ca-certificates \
    bash \
    iproute2 \
    libc6-compat \
    tzdata

# 将脚本复制到镜像中
COPY x-cf.sh .

# 赋予脚本执行权限
RUN chmod +x x-cf.sh

# 启动命令
CMD ./x-cf.sh && tail -f /app/x_cf/run.log
