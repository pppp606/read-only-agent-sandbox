FROM python:3.13-alpine
WORKDIR /app
COPY egress_proxy.py /app/egress_proxy.py
USER 65534:65534
EXPOSE 3128
CMD ["python", "-u", "/app/egress_proxy.py"]
