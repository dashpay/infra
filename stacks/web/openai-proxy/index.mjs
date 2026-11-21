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
        // A function URL hands over a body with a binary content type in base64.
        body: event.isBase64Encoded && event.body
            ? Buffer.from(event.body, 'base64').toString('utf8')
            : event.body
    };

    try {
        console.log('Sending request');
        const res = await fetch('https://api.openai.com/v1/chat/completions', requestOptions);
        const data = await res.json();
        console.log('Received response');

        // OpenAI's own status, so a caller can tell a 429 or a 400 from an answer.
        const response = {
            statusCode: res.status,
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
