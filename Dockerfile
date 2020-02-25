FROM nginx:1.17-alpine as build_modsecurity

RUN apk add --no-cache --virtual .build-deps \
        gcc \
        libc-dev \
        make \
        openssl-dev \
        pcre-dev \
        zlib-dev \
        linux-headers \
        curl \
        gnupg \
        libxslt-dev \
        gd-dev \
        perl-dev \
    && apk add --no-cache --virtual .libmodsecurity-deps \
        pcre-dev \
        libxml2-dev \
        git \
        libtool \
        automake \
        autoconf \
        g++ \
        flex \
        bison \
        yajl-dev \
        lua-dev \
        curl-dev \
    # Add runtime dependencies that should not be removed
    && apk add --no-cache \
        geoip \
        geoip-dev \
        yajl \
        libstdc++ \
        git \
        sed \
        lua \
        libcurl \
        libmaxminddb-dev

RUN wget --quiet https://github.com/ssdeep-project/ssdeep/releases/download/release-2.14.1/ssdeep-2.14.1.tar.gz \
    && tar -xvzf ssdeep-2.14.1.tar.gz \
    && cd ssdeep-2.14.1 \
    && ./configure \
    && make \
    && make install

WORKDIR /opt/ModSecurity

ENV MODSEC_VERSION=3.0.4

RUN echo "Installing ModSec Library" && \
    git clone -b v${MODSEC_VERSION} --single-branch https://github.com/SpiderLabs/ModSecurity . && \
    git submodule init && \
    git submodule update && \
    ./build.sh && \
    ./configure && \
    make -j "$(nproc)" && \
    make install

WORKDIR /opt

ENV MODSEC_NGX_VERSION=1.0.1

RUN echo 'Installing ModSec - Nginx connector' && \
    git clone -b v${MODSEC_NGX_VERSION} --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git && \
    wget http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz && \
    tar zxvf nginx-$NGINX_VERSION.tar.gz

WORKDIR /opt/GeoIP

RUN git clone -b master --single-branch https://github.com/leev/ngx_http_geoip2_module.git .

WORKDIR /opt/nginx-$NGINX_VERSION

RUN ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx  --add-dynamic-module=../GeoIP && \
    make -j "$(nproc)" modules && \
    cp objs/ngx_http_modsecurity_module.so objs/ngx_http_geoip2_module.so /etc/nginx/modules && \
    rm -f /usr/local/modsecurity/lib/libmodsecurity.a /usr/local/modsecurity/lib/libmodsecurity.la

WORKDIR /opt

ENV OWASP_VERSION=v3.1/dev

RUN echo "Begin installing ModSec OWASP Rules" && \
    git clone -b ${OWASP_VERSION} https://github.com/SpiderLabs/owasp-modsecurity-crs && \
    mv owasp-modsecurity-crs/crs-setup.conf.example owasp-modsecurity-crs/crs-setup.conf && \
    mv owasp-modsecurity-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example owasp-modsecurity-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf && \
    mv owasp-modsecurity-crs/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example owasp-modsecurity-crs/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf && \
    mv owasp-modsecurity-crs/ /usr/local/

RUN mkdir -p /etc/nginx/modsec && \
    wget --quiet -O /etc/nginx/modsec/modsecurity.conf https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended && \
    wget --quiet -O /etc/nginx/modsec/unicode.mapping https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/unicode.mapping

#ENV MAXMIND_VER=20200218

#COPY GeoLite2-City_${MAXMIND_VER}.tar.gz .
#COPY GeoLite2-Country_${MAXMIND_VER}.tar.gz .
#RUN mkdir -p /etc/nginx/geoip && \
#    tar -xvzf GeoLite2-City_${MAXMIND_VER}.tar.gz --strip-components=1 && \
#    tar -xvzf GeoLite2-Country_${MAXMIND_VER}.tar.gz --strip-components=1 && \
#    mv *.mmdb /etc/nginx/geoip/

RUN chown -R nginx:nginx /usr/share/nginx /etc/nginx

# cleanup
RUN rm -rf /usr/local/bin/ssdeep \
           /usr/local/lib/*.a \
           /usr/local/modsecurity/include \
           /usr/local/modsecurity/lib/pkgconfig \
           /usr/local/share/man; \
    strip -g /usr/local/lib/*.so.* \
             /usr/local/modsecurity/lib/libmodsecurity.so.*

RUN sed -i '1iload_module modules/ngx_http_modsecurity_module.so;\nload_module modules/ngx_http_geoip2_module.so;' /etc/nginx/nginx.conf

FROM nginx:1.17-alpine

LABEL maintainer="Andrew Kimball"

RUN mkdir /etc/nginx/modsec && \
    rm -fr /etc/nginx/conf.d/ && \
    rm -fr /etc/nginx/nginx.conf

# Copy nginx config from the intermediate container
COPY --from=build_modsecurity /etc/nginx/. /etc/nginx/
# Copy the /usr/local folder from the intermediate container (owasp-modsecurty-crs, modsecurity libs)
COPY --from=build_modsecurity /usr/local/. /usr/local/.
COPY --from=build_modsecurity /usr/lib/nginx/modules/. /usr/lib/nginx/modules/

RUN apk upgrade --no-cache \
      && apk add --no-cache \
             yajl \
             lua \
             libcurl \
             libstdc++ \
             libmaxminddb-dev \
             tzdata \
      && chown -R nginx:nginx /usr/share/nginx /etc/nginx

WORKDIR /usr/share/nginx/html
