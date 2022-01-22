precision highp float;
precision highp int;
precision highp sampler2D;

uniform mat4 uShortBoxInvMatrix;
uniform mat4 uTallBoxInvMatrix;

#include <pathtracing_uniforms_and_defines>

#define N_QUADS 6
#define N_BOXES 3

vec3 rayOrigin, rayDirection;
// recorded intersection data:
vec3 hitNormal, hitEmission, hitColor;
vec2 hitUV;
float hitObjectID;
int hitType;

struct Quad { vec3 normal; vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; int type; };
struct Box { vec3 minCorner; vec3 maxCorner; vec3 emission; vec3 color; int type; };

Quad quads[N_QUADS];
Box boxes[N_BOXES];


#include <pathtracing_random_functions>

#include <pathtracing_quad_intersect>

#include <pathtracing_box_intersect>


//---------------------------------------------------------------------------------------
float SceneIntersect( )
//---------------------------------------------------------------------------------------
{
	vec3 normal;
	vec3 rObjOrigin, rObjDirection;
        float d;
	float t = INFINITY;
	bool isRayExiting = false;
	int objectCount = 0;
	
	hitObjectID = -INFINITY;
	
	for (int i = 0; i < N_QUADS; i++)
        {
		d = QuadIntersect( quads[i].v0, quads[i].v1, quads[i].v2, quads[i].v3, rayOrigin, rayDirection, false );
		if (d < t)
		{
			t = d;
			hitNormal = normalize(quads[i].normal);
			hitEmission = quads[i].emission;
			hitColor = quads[i].color;
			hitType = quads[i].type;
			hitObjectID = float(objectCount);
		}
		objectCount++;
        }
	
	// LIGHT-BLOCKER THIN BOX
	d = BoxIntersect( boxes[2].minCorner, boxes[2].maxCorner, rayOrigin, rayDirection, normal, isRayExiting );
	if (d < t)
	{
		t = d;
		hitNormal = normalize(normal);
		hitEmission = boxes[2].emission;
		hitColor = boxes[2].color;
		hitType = boxes[2].type;
		hitObjectID = float(objectCount);
	}
	objectCount++;
	
	
	// TALL MIRROR BOX
	// transform ray into Tall Box's object space
	rObjOrigin = vec3( uTallBoxInvMatrix * vec4(rayOrigin, 1.0) );
	rObjDirection = vec3( uTallBoxInvMatrix * vec4(rayDirection, 0.0) );
	d = BoxIntersect( boxes[0].minCorner, boxes[0].maxCorner, rObjOrigin, rObjDirection, normal, isRayExiting );
	
	if (d < t)
	{	
		t = d;
		
		// transfom normal back into world space
		normal = normalize(normal);
		hitNormal = normalize(transpose(mat3(uTallBoxInvMatrix)) * normal);
		hitEmission = boxes[0].emission;
		hitColor = boxes[0].color;
		hitType = boxes[0].type;
		hitObjectID = float(objectCount);
	}
	objectCount++;
	
	// SHORT DIFFUSE WHITE BOX
	// transform ray into Short Box's object space
	rObjOrigin = vec3( uShortBoxInvMatrix * vec4(rayOrigin, 1.0) );
	rObjDirection = vec3( uShortBoxInvMatrix * vec4(rayDirection, 0.0) );
	d = BoxIntersect( boxes[1].minCorner, boxes[1].maxCorner, rObjOrigin, rObjDirection, normal, isRayExiting );
	
	if (d < t)
	{	
		t = d;
		
		// transfom normal back into world space
		normal = normalize(normal);
		hitNormal = normalize(transpose(mat3(uShortBoxInvMatrix)) * normal);
		hitEmission = boxes[1].emission;
		hitColor = boxes[1].color;
		hitType = boxes[1].type;
		hitObjectID = float(objectCount);
	}
	
	
	return t;
} // end float SceneIntersect( )



//---------------------------------------------------------------------------------------------------------------------------------------
vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )
//---------------------------------------------------------------------------------------------------------------------------------------
{	
	vec3 originalRayOrigin = rayOrigin;
	vec3 originalRayDirection = rayDirection;
	
	vec3 accumCol = vec3(0);
        vec3 mask = vec3(1);
	vec3 n, nl, x;
	vec3 dirToLight;
	vec3 tdir;
	vec3 randPointOnLight = vec3( mix(quads[5].v0.x, quads[5].v2.x, rng()),
				      quads[5].v0.y,
				      mix(quads[5].v0.z, quads[5].v2.z, rng()) );
	vec3 lightHitPos = randPointOnLight;
	vec3 lightHitEmission = quads[5].emission;
        
	float lightHitDistance = INFINITY;
	float t = INFINITY;
	float weight = 0.0;
	
	int diffuseCount = 0;
	int previousIntersecType = -100;

	bool bounceIsSpecular = true;
	bool sampleLight = false;
	bool ableToJoinPaths = false;
	bool diffuseFound = false;

	// first light trace
	rayDirection = quads[5].normal;
	rayOrigin = randPointOnLight + quads[5].normal * uEPS_intersect;
	t = SceneIntersect();

	if (t < INFINITY && hitType == DIFF)
	{
		diffuseFound = true;
		lightHitPos = rayOrigin + rayDirection * t;
		weight = max(0.0, dot(-rayDirection, normalize(hitNormal)));
		lightHitEmission *= hitColor  * weight;

		// second light trace
		hitNormal = normalize(hitNormal);
		rayDirection = randomCosWeightedDirectionInHemisphere(hitNormal);
		rayOrigin = lightHitPos + hitNormal * uEPS_intersect;
		
		t = SceneIntersect();
		if (t < INFINITY && hitType == DIFF && rand() < 0.5)
		{
			lightHitPos = rayOrigin + rayDirection * t;
			weight = max(0.0, dot(-rayDirection, normalize(hitNormal)));
			lightHitEmission *= hitColor * weight;

			/* // third light trace
			hitNormal = normalize(hitNormal);
			rayDirection = randomCosWeightedDirectionInHemisphere(hitNormal);
			rayOrigin = lightHitPos + hitNormal * uEPS_intersect;
			t = SceneIntersect();
			if (t < INFINITY && hitType == DIFF && rand() < 0.2)
			{
				lightHitPos = rayOrigin + rayDirection * t;
				weight = max(0.0, dot(-rayDirection, normalize(hitNormal)));
				lightHitEmission *= hitColor * weight;
			} */
		}

	}

	// this allows the original light to be the lightsource once in a while
	if ( !diffuseFound || rng() < 0.5 )
	{
		lightHitPos = randPointOnLight;
		lightHitEmission = quads[5].emission;
	}


	// regular path tracing from camera
	rayOrigin = originalRayOrigin;
	rayDirection = originalRayDirection;

	hitObjectID = -INFINITY;

	for (int bounces = 0; bounces < 5; bounces++)
	{

		t = SceneIntersect();
		
		if (t == INFINITY)
			break;

		// useful data 
		n = normalize(hitNormal);
                nl = dot(n, rayDirection) < 0.0 ? normalize(n) : normalize(-n);
		x = rayOrigin + rayDirection * t;

		if (bounces == 0)
		{
			objectNormal = nl;
			objectColor = hitColor;
			objectID = hitObjectID;
		}
		if (bounces == 1 && previousIntersecType == SPEC)
		{
			objectNormal = nl;
		}
		
		
		if (hitType == LIGHT)
		{	
			if (diffuseCount == 0)
				pixelSharpness = 1.01;
			
			if (sampleLight)
				accumCol = mask * hitEmission * max(0.0, dot(-rayDirection, nl));

			else
				accumCol = mask * hitEmission;
			// reached a light, so we can exit
			break;
		}


		if (hitType == DIFF && sampleLight)
		{
			ableToJoinPaths = abs(lightHitDistance - t) < 0.5;

			if (ableToJoinPaths)
			{
				weight = max(0.0, dot(nl, -rayDirection));
				accumCol = mask * lightHitEmission * weight;
			}
			
			break;
		}

		// if we reached this point and sampleLight is still true, then we can 
		//  exit because the light was not found
		if (sampleLight)
			break;


                if (hitType == DIFF) // Ideal DIFFUSE reflection
		{
			diffuseCount++;

			previousIntersecType = DIFF;

			mask *= hitColor;

			bounceIsSpecular = false;

			if (diffuseCount < 3 && rand() < 0.5)
			{	
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}
			
			dirToLight = normalize(lightHitPos - x);
			
			weight = max(0.0, dot(nl, dirToLight));
			mask *= weight;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;
			lightHitDistance = distance(rayOrigin, lightHitPos);

			sampleLight = true;
			continue;
			
		} // end if (hitType == DIFF)
		
		if (hitType == SPEC)  // Ideal SPECULAR reflection
		{
			previousIntersecType = SPEC;

			mask *= hitColor;

			rayDirection = reflect(rayDirection, nl);
			rayOrigin = x + nl * uEPS_intersect;

			//bounceIsSpecular = true; // turn on mirror caustics
			continue;
		}
		
	} // end for (int bounces = 0; bounces < 5; bounces++)
	
	
	return max(vec3(0), accumCol);
	      
}



//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black
	vec3 L1 = vec3(1.0, 0.75, 0.4) * 30.0;// Bright Yellowish light
	//L1 = vec3(30);
	quads[0] = Quad( vec3( 0.0, 0.0, 1.0), vec3(  0.0,   0.0,-559.2), vec3(549.6,   0.0,-559.2), vec3(549.6, 548.8,-559.2), vec3(  0.0, 548.8,-559.2),  z, vec3(1),  DIFF);// Back Wall
	quads[1] = Quad( vec3( 1.0, 0.0, 0.0), vec3(  0.0,   0.0,   0.0), vec3(  0.0,   0.0,-559.2), vec3(  0.0, 548.8,-559.2), vec3(  0.0, 548.8,   0.0),  z, vec3(0.7, 0.12,0.05), DIFF);// Left Wall Red
	quads[2] = Quad( vec3(-1.0, 0.0, 0.0), vec3(549.6,   0.0,-559.2), vec3(549.6,   0.0,   0.0), vec3(549.6, 548.8,   0.0), vec3(549.6, 548.8,-559.2),  z, vec3(0.2, 0.4, 0.36), DIFF);// Right Wall Green
	quads[3] = Quad( vec3( 0.0,-1.0, 0.0), vec3(  0.0, 548.8,-559.2), vec3(549.6, 548.8,-559.2), vec3(549.6, 548.8,   0.0), vec3(  0.0, 548.8,   0.0),  z, vec3(1),  DIFF);// Ceiling
	quads[4] = Quad( vec3( 0.0, 1.0, 0.0), vec3(  0.0,   0.0,   0.0), vec3(549.6,   0.0,   0.0), vec3(549.6,   0.0,-559.2), vec3(  0.0,   0.0,-559.2),  z, vec3(1),  DIFF);// Floor
	quads[5] = Quad( vec3( 0.0,-1.0, 0.0), vec3(213.0, 548.0,-332.0), vec3(343.0, 548.0,-332.0), vec3(343.0, 548.0,-227.0), vec3(213.0, 548.0,-227.0), L1,       z, LIGHT);// Area Light Rectangle in ceiling
	
	boxes[0] = Box( vec3(-82.0,-170.0, -80.0), vec3(82.0,170.0, 80.0), z, vec3(1), SPEC);// Tall Mirror Box Left
	boxes[1] = Box( vec3(-86.0, -85.0, -80.0), vec3(86.0, 85.0, 80.0), z, vec3(1), DIFF);// Short Diffuse Box Right
	
	boxes[2] = Box( vec3(183.0, 534.0, -362.0), vec3(373.0, 535.0, -197.0), z, vec3(1), DIFF);// Light Blocker Box
	//boxes[2] = Box( vec3(183.0, 500.0, -362.0), vec3(373.0, 530.0, -197.0), z, vec3(1), DIFF);// Light Blocker Box
}


#include <pathtracing_main>
