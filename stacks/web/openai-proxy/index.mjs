/* global fetch */

import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const openaiApiKeySecretName = process.env.SSM_OPENAI_AUTHORIZATION_PARAMETER;
const ssmClient = new SSMClient();
const getOpenAIParameterCommand = new GetParameterCommand({ "Name": openaiApiKeySecretName, WithDecryption: true });
const openAIAPIKey = await ssmClient.send(getOpenAIParameterCommand);

export async function handler(event) {
    console.log('event data');
    console.dir(event, { depth: null });

    const requestOptions = {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${openAIAPIKey.Parameter.Value}`
        },
        body: event.body
    };

    try {
        console.log('Sending request');
        const res = await fetch('https://api.openai.com/v1/chat/completions', requestOptions);
        const data = await res.json();
        console.log('Received response');

        const response = {
            statusCode: 200,
            body: JSON.stringify(data),
        };

        console.log('Returning response');
        console.dir(response, { depth: null });

        return response;
    } catch (error) {
        console.error(error);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: 'An error occurred' }),
        };
    }
}
