# Dependencies are installed at image build time, before the test service
# joins its intentionally internal-only network.
FROM mcr.microsoft.com/playwright:v1.49.1-jammy
WORKDIR /e2e
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY run-e2e.mjs ./
ENTRYPOINT ["node", "run-e2e.mjs"]
