import boto3
import json
import logging
import os
from botocore.exceptions import ClientError

# Control Tower governed regions (exclude from VPC deletion - as AFT already handles them)
CONTROL_TOWER_REGIONS = {
    'us-east-1',      # N. Virginia
    'us-west-2',      # Oregon
    'ap-south-1',     # Mumbai
    'ap-northeast-2', # Seoul
    'eu-west-1'       # Ireland
}

def lambda_handler(event, context):
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
    logging.getLogger().setLevel(LOG_LEVEL)
    
    try:
        logging.info(f'Event: {json.dumps(event)}')
        
        # Parse SQS message
        for record in event['Records']:
            message_body = json.loads(record['body'])
            account_id = message_body['accountId']
            account_name = message_body['accountName']
            
            logging.info(f'Processing VPC cleanup for account: {account_id} ({account_name})')
            
            # Assume AWSControlTowerExecution role in target account
            sts_client = boto3.client('sts')
            role_arn = f'arn:aws:iam::{account_id}:role/AWSControlTowerExecution'
            
            try:
                assumed_role = sts_client.assume_role(
                    RoleArn=role_arn,
                    RoleSessionName=f'vpc-cleanup-{account_id}'
                )
                
                credentials = assumed_role['Credentials']
                session = boto3.Session(
                    aws_access_key_id=credentials['AccessKeyId'],
                    aws_secret_access_key=credentials['SecretAccessKey'],
                    aws_session_token=credentials['SessionToken']
                )
                
                # Get all opted-in regions for the account
                ec2_client = session.client('ec2', region_name='eu-west-1')  # Use eu-west-1 to get all regions
                regions_response = ec2_client.describe_regions(
                    AllRegions=False,
                    Filters=[
                        {
                            'Name': 'opt-in-status',
                            'Values': ['opt-in-not-required', 'opted-in']
                        }
                    ]
                )
                
                opted_in_regions = [region['RegionName'] for region in regions_response['Regions']]
                logging.info(f'Opted-in regions for account {account_id}: {opted_in_regions}')
                
                # Delete default VPCs in non-Control Tower regions
                for region in opted_in_regions:
                    if region not in CONTROL_TOWER_REGIONS:
                        delete_default_vpc_in_region(session, region, account_id)
                    else:
                        logging.info(f'Skipping Control Tower governed region: {region}')
                
            except ClientError as e:
                if e.response['Error']['Code'] == 'AccessDenied':
                    logging.error(f'Access denied assuming role in account {account_id}. Role may not exist yet.')
                else:
                    logging.error(f'Error assuming role in account {account_id}: {str(e)}')
                    raise e
        
        return {'statusCode': 200}
    
    except Exception as e:
        logging.exception(f'Error processing SQS message: {str(e)}')
        raise e

def delete_default_vpc_in_region(session, region, account_id):
    """Delete default VPC in a specific region"""
    try:
        ec2_client = session.client('ec2', region_name=region)
        ec2_resource = session.resource('ec2', region_name=region)
        
        # Find default VPC
        vpcs_response = ec2_client.describe_vpcs()
        default_vpc_id = None
        
        for vpc in vpcs_response['Vpcs']:
            if vpc.get('IsDefault', False):
                default_vpc_id = vpc['VpcId']
                break
        
        if not default_vpc_id:
            logging.info(f'No default VPC found in region {region} for account {account_id}')
            return
        
        logging.info(f'Found default VPC {default_vpc_id} in region {region} for account {account_id}')
        
        vpc = ec2_resource.Vpc(default_vpc_id)
        
        # Delete Internet Gateways
        logging.info(f'Deleting internet gateways for VPC {default_vpc_id}')
        for igw in vpc.internet_gateways.all():
            vpc.detach_internet_gateway(InternetGatewayId=igw.id)
            igw.delete()
        
        # Delete route table associations (except main)
        logging.info(f'Deleting route table associations for VPC {default_vpc_id}')
        for route_table in vpc.route_tables.all():
            for association in route_table.associations:
                if not association.main:
                    association.delete()
        
        # Delete security groups (except default)
        logging.info(f'Deleting security groups for VPC {default_vpc_id}')
        for sg in vpc.security_groups.all():
            if sg.group_name != 'default':
                sg.delete()
        
        # Delete subnets and network interfaces
        logging.info(f'Deleting subnets for VPC {default_vpc_id}')
        for subnet in vpc.subnets.all():
            for eni in subnet.network_interfaces.all():
                eni.delete()
            subnet.delete()
        
        # Finally delete the VPC
        logging.info(f'Deleting VPC {default_vpc_id}')
        ec2_client.delete_vpc(VpcId=default_vpc_id)
        
        logging.info(f'Successfully deleted default VPC {default_vpc_id} in region {region} for account {account_id}')
        
    except ClientError as e:
        if e.response['Error']['Code'] == 'InvalidVpcID.NotFound':
            logging.info(f'VPC {default_vpc_id} not found in region {region} (may have been deleted already)')
        else:
            logging.error(f'Error deleting default VPC in region {region} for account {account_id}: {str(e)}')
            raise e
    except Exception as e:
        logging.error(f'Unexpected error deleting default VPC in region {region} for account {account_id}: {str(e)}')
        raise e