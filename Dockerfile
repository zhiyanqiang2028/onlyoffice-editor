# Use this (large) base image in every build below, to reduce the overall docker cache size
FROM ubuntu:24.04 AS base
RUN apt-get update && apt-get install -y openjdk-21-jdk npm wget zip brotli
RUN npm install -g pnpm && pnpm config set registry https://registry.npmmirror.com
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN pnpm env use --global lts
RUN pnpm install -g grunt

###################### onlyoffice-editor-build ################################
FROM base AS onlyoffice-editor-build
WORKDIR /app
COPY onlyoffice-editor/package.json /app
COPY onlyoffice-editor/pnpm-lock.yaml /app
RUN pnpm install
COPY onlyoffice-editor/tsconfig.json /app
COPY onlyoffice-editor/webpack.config.mjs /app
COPY onlyoffice-editor/src/ /app/src
RUN pnpm build

FROM onlyoffice-editor-build AS onlyoffice-editor-test
COPY onlyoffice-editor/eslint.config.mjs /app
COPY onlyoffice-editor/.prettierignore /app
COPY .editorconfig /app
RUN pnpm lint


###################### sdkjs & web-apps ################################
FROM base AS sdkjs-build
COPY sdkjs /app/sdkjs
COPY web-apps /app/web-apps

# 安装 ARM64 兼容的系统级图片优化工具，替代 npm 无法在 ARM64 安装的 prebuilt 二进制包
RUN apt-get install -y optipng libjpeg-turbo-progs gifsicle

# ignore-scripts 避免 phantomjs-prebuilt 在 ARM64 上的 postinstall 报错
RUN npm config set ignore-scripts true

# 预先在 web-apps/build 中安装依赖，然后为各 imagemin 工具创建指向系统二进制的符号链接
RUN cd /app/web-apps/build && npm install && \
    mkdir -p node_modules/optipng-bin/vendor && \
    ln -sf /usr/bin/optipng node_modules/optipng-bin/vendor/optipng && \
    mkdir -p node_modules/jpegtran-bin/vendor && \
    ln -sf /usr/bin/jpegtran node_modules/jpegtran-bin/vendor/jpegtran && \
    mkdir -p node_modules/gifsicle/vendor && \
    ln -sf /usr/bin/gifsicle node_modules/gifsicle/vendor/gifsicle

COPY fonts/*.png /app/sdkjs/common/Images
COPY fonts/*.js /app/sdkjs/common
WORKDIR /app/sdkjs
# node_modules 已存在，make 会跳过 npm install 直接运行 grunt
RUN make
RUN mv deploy/web-apps/apps/api/documents/api.js deploy/web-apps/apps/api/documents/api-orig.js


FROM base AS zip-build
COPY --from=sdkjs-build /app/sdkjs/deploy/web-apps /app/web-apps
COPY --from=sdkjs-build /app/sdkjs/deploy/sdkjs /app/sdkjs
COPY vendor /app/web-apps/vendor
COPY fonts/*.ttf /app/fonts/fonts/
COPY fonts/*.otf /app/fonts/fonts/
COPY dictionaries /app/dictionaries
COPY --from=onlyoffice-editor-build /app/dist/api.js /app/web-apps/apps/api/documents/api.js
WORKDIR /app
RUN find . -name "*.wasm" \
    -o -name "*.js" \
    -o -name "*.html" \
    -o -name "*.css" \
    -o -name "*.aff" \
    -o -name "*.dic" \
    | xargs -P 8 -n 16 -- brotli
RUN zip -r onlyoffice-editor.zip .
RUN sha512sum onlyoffice-editor.zip > onlyoffice-editor.zip.sha512



FROM zip-build AS zip-test
RUN unzip -l onlyoffice-editor.zip > zip.content
RUN grep ' sdkjs/common/AllFonts.js' zip.content
RUN grep ' sdkjs/common/Images/fonts_thumbnail@2x.png' zip.content
RUN grep ' fonts/fonts/calibri.ttf' zip.content


FROM scratch AS build
COPY --from=zip-build /app/onlyoffice-editor.zip /
COPY --from=zip-build /app/onlyoffice-editor.zip.sha512 /
