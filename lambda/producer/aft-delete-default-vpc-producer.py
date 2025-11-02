import boto3
import json
import logging
import os

def lambda_handler(event, context):
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
    logging.getLogger().setLevel(LOG_LEVEL)
    
    try:
        logging.info(f'Event Data: {json.dumps(event)}')
        
        sqs_queue_url = os.getenv('SQS_QUEUE_URL')
        if not sqs_queue_url:
            raise ValueError("SQS_QUEUE_URL environment variable not set")
        
        # Extract account information from CreateManagedAccount event
        if event.get('source') == 'aws.controltower' and \
           event.get('detail', {}).get('eventName') == 'CreateManagedAccount':
            
            # Check if this is a completion event (has serviceEventDetails)
            service_event_details = event.get('detail', {}).get('serviceEventDetails')
            if not service_event_details or 'createManagedAccountStatus' not in service_event_details:
                logging.info('Skipping event -> not CreateManagedAccount API triggered by Control Tower')
                return {'statusCode': 200}
            
            # Check if the account creation was successful
            create_status = service_event_details['createManagedAccountStatus']
            state = create_status.get('state')
            
            if state != 'SUCCEEDED':
                logging.info(f'Skipping event - account creation state is: {state}')
                return {'statusCode': 200}
            
            account_details = create_status['account']
            account_id = account_details['accountId']
            account_name = account_details['accountName']
            
            # Extract organizational unit information
            ou_details = create_status.get('organizationalUnit', {})
            ou_name = ou_details.get('organizationalUnitName', 'Unknown')
            ou_id = ou_details.get('organizationalUnitId', 'Unknown')
            
            logging.info(f'Processing SUCCEEDED CreateManagedAccount for account: {account_id} ({account_name}) in OU: {ou_name} ({ou_id})')
            
            # Send message to SQS queue
            sqs_client = boto3.client('sqs')
            message_body = {
                'accountId': account_id,
                'accountName': account_name,
                'organizationalUnitName': ou_name,
                'organizationalUnitId': ou_id,
                'state': state,
                'eventName': 'CreateManagedAccount',
                'eventTime': event['detail']['eventTime'],
                'completedTimestamp': create_status.get('completedTimestamp'),
                'requestedTimestamp': create_status.get('requestedTimestamp')
            }
            
            response = sqs_client.send_message(
                QueueUrl=sqs_queue_url,
                MessageBody=json.dumps(message_body)
            )
            
            logging.info(f'Message sent to SQS: {json.dumps(message_body)}')
            logging.info(f'SQS Response: {response}')
            
        else:
            logging.info('Event does not match CreateManagedAccount pattern')
        
        return {'statusCode': 200}
    
    except Exception as e:
        logging.exception(f'Error processing event: {str(e)}')
        raise e