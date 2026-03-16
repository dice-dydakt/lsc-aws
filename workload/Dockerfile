FROM public.ecr.aws/lambda/python:3.12

COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

COPY app.py handler.py generate_dataset.py ${LAMBDA_TASK_ROOT}/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default: Lambda mode (handler specified as CMD)
# For Fargate/EC2: set MODE=server to run Flask
ENTRYPOINT ["/entrypoint.sh"]
CMD ["handler.lambda_handler"]
