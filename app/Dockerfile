# syntax=docker/dockerfile:1
FROM python:3.12-alpine AS build
WORKDIR /src
COPY main.py .
# Fail the build on syntax errors.
RUN python -m py_compile main.py

FROM python:3.12-alpine
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080
RUN addgroup -g 10001 -S app && adduser -u 10001 -S -G app -H -s /sbin/nologin app
WORKDIR /app
COPY --from=build /src/main.py .
USER 10001:10001
EXPOSE 8080
CMD ["python", "main.py"]
