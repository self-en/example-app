FROM node:20-alpine

WORKDIR /app

COPY backend/package*.json ./backend/
RUN npm --prefix backend ci --omit=dev

COPY backend ./backend
COPY frontend ./frontend

ENV PORT=3000
EXPOSE 3000

CMD ["node", "backend/src/index.js"]
