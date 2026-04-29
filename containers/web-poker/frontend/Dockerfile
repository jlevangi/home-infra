FROM alpine/git:2.45.2 AS source
ARG WEB_POKER_REF=master
WORKDIR /src
RUN git clone --depth 1 --branch "${WEB_POKER_REF}" https://github.com/alexander171294/web-poker.git web-poker
WORKDIR /src/web-poker
COPY containers/web-poker/overrides/frontend/src/app/services/network/room.service.ts /src/web-poker/frontend/newClient/src/app/services/network/room.service.ts
COPY containers/web-poker/overrides/frontend/src/app/services/network/utils/web-socket.service.ts /src/web-poker/frontend/newClient/src/app/services/network/utils/web-socket.service.ts
COPY containers/web-poker/overrides/frontend/src/app/pages/lobby/components/table/table.component.html /src/web-poker/frontend/newClient/src/app/pages/lobby/components/table/table.component.html
COPY containers/web-poker/overrides/frontend/src/app/utils/components/soon-modal/soon-modal.component.html /src/web-poker/frontend/newClient/src/app/utils/components/soon-modal/soon-modal.component.html
COPY containers/web-poker/overrides/frontend/src/environments/environment.prod.ts /src/web-poker/frontend/newClient/src/environments/environment.prod.ts

FROM node:16-bullseye AS build
WORKDIR /work
COPY --from=source /src/web-poker/frontend/newClient/ ./
RUN npm install --legacy-peer-deps
RUN npm run build -- --configuration production

FROM nginx:1.27-alpine
COPY containers/web-poker/frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /work/dist/newClient/ /usr/share/nginx/html/
