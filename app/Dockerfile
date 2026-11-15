#Stage 1 Build the application
FROM python:3.12-alpine AS build
WORKDIR /src
COPY main.py .
RUN python -m py_compile main.py
#Stage 2 Run the application
FROM python:3.12-alpine
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080
# Apply OS security patches that are newer than the base image (fixes the krb5-libs HIGH findings from Trivy).
RUN apk upgrade --no-cache
RUN addgroup -g 10001 -S app && adduser -u 10001 -S -G app -H -s /sbin/nologin app
WORKDIR /app
COPY --from=build /src/main.py .
USER 10001:10001
EXPOSE 8080
CMD ["python", "main.py"]
