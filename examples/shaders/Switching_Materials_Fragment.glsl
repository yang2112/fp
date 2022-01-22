precision highp float;
precision highp int;
precision highp sampler2D;

#include <pathtracing_uniforms_and_defines>

uniform float uLeftSphereMaterialType;
uniform float uRightSphereMaterialType;
uniform vec3 uLeftSphereColor;
uniform vec3 uRightSphereColor;


#define N_QUADS 6
#define N_SPHERES 2


vec3 rayOrigin, rayDirection;
// recorded intersection data:
vec3 hitNormal, hitEmission, hitColor;
vec2 hitUV;
float hitObjectID;
int hitType;


struct Sphere { float radius; vec3 position; vec3 emission; vec3 color; int type; };
struct Quad { vec3 normal; vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; int type; };

Quad quads[N_QUADS];
Sphere spheres[N_SPHERES];


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_quad_intersect>

#include <pathtracing_sample_quad_light>


//---------------------------------------------------------------------------------------
float SceneIntersect( )
//---------------------------------------------------------------------------------------
{
	float d;
	float t = INFINITY;
	int objectCount = 0;
	
	hitObjectID = -INFINITY;

	
        for (int i = 0; i < N_SPHERES; i++)
        {
		d = SphereIntersect( spheres[i].radius, spheres[i].position, rayOrigin, rayDirection );
		if (d < t)
		{
			t = d;
			hitNormal = normalize((rayOrigin + rayDirection * t) - spheres[i].position);
			hitEmission = spheres[i].emission;
			hitColor = spheres[i].color;
                        hitType = spheres[i].type;
			hitObjectID = float(objectCount);
		}
		objectCount++;
        }
	
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
	
	return t;
} // end float SceneIntersect( )


//-----------------------------------------------------------------------------------------------------------------------------
vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )
//-----------------------------------------------------------------------------------------------------------------------------
{
	Quad light = quads[5];

	vec3 accumCol = vec3(0);
        vec3 mask = vec3(1);
	vec3 dirToLight;
	vec3 tdir;
	vec3 x, n, nl;
	vec3 absorptionCoefficient;
        
	float t;
	float nc, nt, ratioIoR, Re, Tr;
	float P, RP, TP;
	float weight;
	float thickness = 0.05;
	float scatteringDistance;

	int diffuseCount = 0;
	int previousIntersecType = -100;
	hitType = -100;

	bool coatTypeIntersected = false;
	bool bounceIsSpecular = true;
	bool sampleLight = false;
	

	
	for (int bounces = 0; bounces < 6; bounces++)
	{
		previousIntersecType = hitType;

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
			
			if (bounceIsSpecular || sampleLight)
				accumCol = mask * hitEmission;
			// reached a light, so we can exit
			break;

		} // end if (hitType == LIGHT)


		// if we get here and sampleLight is still true, shadow ray failed to find a light source
		if (sampleLight)	
			break;
		

		    
                if (hitType == DIFF) // Ideal DIFFUSE reflection
		{
			diffuseCount++;

			mask *= hitColor;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}
                        
			dirToLight = sampleQuadLight(x, nl, quads[5], weight);
			mask *= weight;

			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;

			sampleLight = true;
			continue;
                        
		} // end if (hitType == DIFF)
		
		if (hitType == SPEC)  // Ideal SPECULAR reflection
		{
			mask *= hitColor;

			rayDirection = reflect(rayDirection, nl);
			rayOrigin = x + nl * uEPS_intersect;
			continue;
		}
		
		if (hitType == REFR)  // Ideal dielectric REFRACTION
		{
			if (diffuseCount == 0 && !coatTypeIntersected && !uCameraIsMoving )
				pixelSharpness = 1.01;
			else if (diffuseCount > 0)
				pixelSharpness = 0.0;
			else
				pixelSharpness = -1.0;

			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of common Glass
			Re = calcFresnelReflectance(rayDirection, n, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);
			
			if (rand() < P)
			{
				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			// transmit ray through surface
			
			// is ray leaving a solid object from the inside? 
			// If so, attenuate ray color with object color by how far ray has travelled through the medium
			if (distance(n, nl) > 0.1)
			{
				thickness = 0.01;
				mask *= exp( log(clamp(hitColor, 0.01, 0.99)) * thickness * t ); 
			}

			mask *= TP;
			
			tdir = refract(rayDirection, nl, ratioIoR);
			rayDirection = tdir;
			rayOrigin = x - nl * uEPS_intersect;

			if (diffuseCount == 1)
				bounceIsSpecular = true; // turn on refracting caustics
			
			continue;
			
		} // end if (hitType == REFR)
		
		if (hitType == COAT)  // Diffuse object underneath with ClearCoat on top
		{
			coatTypeIntersected = true;

			pixelSharpness = 0.0;

			nc = 1.0; // IOR of Air
			nt = 1.4; // IOR of Clear Coat
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);

			if (rand() < P)
			{
				if (diffuseCount == 0)
					pixelSharpness = uFrameCounter > 500.0 ? 1.01 : -1.0;

				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			diffuseCount++;
			mask *= TP;
			mask *= hitColor;

			bounceIsSpecular = false;
			
			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			dirToLight = sampleQuadLight(x, nl, quads[5], weight);
			mask *= weight;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;

			sampleLight = true;
			continue;
			
		} //end if (hitType == COAT)

		if (hitType == CARCOAT)  // Colored Metal or Fiberglass object underneath with ClearCoat on top
		{
			nc = 1.0; // IOR of Air
			nt = 1.4; // IOR of Clear Coat
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);

			// choose either specular reflection, metallic, or diffuse
			if (rand() < P)
			{
				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			mask *= TP;

			// metallic component
			mask *= hitColor;
			
			if (rand() > 0.8)
			{
				rayDirection = reflect(rayDirection, nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			diffuseCount++;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
                        {
                                // choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
                        }
                        
			dirToLight = sampleQuadLight(x, nl, quads[5], weight);
			mask *= weight;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;

			sampleLight = true;
			continue;
			
                } //end if (hitType == CARCOAT)


		if (hitType == TRANSLUCENT)  // Translucent Sub-Surface Scattering material
		{
			thickness = 0.25;
			scatteringDistance = -log(rand()) / thickness;
			absorptionCoefficient = clamp(vec3(1) - hitColor, 0.0, 1.0);

			// transmission?
			if (t < scatteringDistance) 
			{
				mask *= exp(-absorptionCoefficient * t);
				
				rayDirection = normalize(rayDirection);
				rayOrigin = x + rayDirection * scatteringDistance;
				continue;
			}

			// else scattering
			mask *= exp(-absorptionCoefficient * scatteringDistance);

			diffuseCount++;

			bounceIsSpecular = false;
			
			if (diffuseCount == 1 && rand() < 0.5)
                        {
                                // choose random scattering direction vector
				rayDirection = randomSphereDirection();
				rayOrigin = x + rayDirection * scatteringDistance;
				continue;
                        }

			dirToLight = sampleQuadLight(x, nl, quads[5], weight);
			mask *= weight;

			rayDirection = dirToLight;
			rayOrigin = x + rayDirection * scatteringDistance;
			
			sampleLight = true;
			continue;
			
		} // end if (hitType == TRANSLUCENT)

		
                if (hitType == SPECSUB)  // Shiny(specular) coating over Sub-Surface Scattering material
		{
			coatTypeIntersected = true;

			pixelSharpness = 0.0;

			nc = 1.0; // IOR of Air
			nt = 1.3; // IOR of clear coating (for polished jade)
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);

			if (rand() < P)
			{
				if (diffuseCount == 0)
					pixelSharpness = uFrameCounter > 500.0 ? 1.01 : -1.0;

				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			mask *= TP;

			thickness = 0.1;
			scatteringDistance = -log(rand()) / thickness;
			absorptionCoefficient = clamp(vec3(1) - hitColor, 0.0, 1.0);
			
			// transmission?
			if (t < scatteringDistance) 
			{
				mask *= exp(-absorptionCoefficient * t);

				rayDirection = normalize(rayDirection);
				rayOrigin = x + rayDirection * scatteringDistance;
				continue;
			}
			
			diffuseCount++;

			bounceIsSpecular = false;

			// else scattering
			mask *= exp(-absorptionCoefficient * scatteringDistance);

			if (rand() < 0.5)
			{
                                // choose random scattering direction vector
				rayDirection = randomSphereDirection();
				rayOrigin = x + rayDirection * scatteringDistance;
				continue;
                        }

			dirToLight = sampleQuadLight(x, nl, quads[5], weight);
			mask *= weight;

			rayDirection = dirToLight;
			rayOrigin = x + rayDirection * scatteringDistance;
			
			sampleLight = true;
			continue;
			
		} // end if (hitType == SPECSUB)
		
	} // end for (int bounces = 0; bounces < 6; bounces++)
	
	
	return max(vec3(0), accumCol);

} // end vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )



//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black        
	vec3 L1 = vec3(1.0, 1.0, 1.0) * 10.0;// Bright light
		    
	spheres[0] = Sphere(  90.0, vec3(150.0,  91.0, -200.0),  z, uLeftSphereColor, int(uLeftSphereMaterialType));// Sphere Left
	spheres[1] = Sphere(  90.0, vec3(400.0,  91.0, -200.0),  z, uRightSphereColor, int(uRightSphereMaterialType));// Sphere Right
	
	quads[0] = Quad( vec3( 0.0, 0.0, 1.0), vec3(  0.0,   0.0,-559.2), vec3(549.6,   0.0,-559.2), vec3(549.6, 548.8,-559.2), vec3(  0.0, 548.8,-559.2), z, vec3( 1.0,  1.0,  1.0), DIFF);// Back Wall
	quads[1] = Quad( vec3( 1.0, 0.0, 0.0), vec3(  0.0,   0.0,   0.0), vec3(  0.0,   0.0,-559.2), vec3(  0.0, 548.8,-559.2), vec3(  0.0, 548.8,   0.0), z, vec3( 0.7, 0.05, 0.05), DIFF);// Left Wall Red
	quads[2] = Quad( vec3(-1.0, 0.0, 0.0), vec3(549.6,   0.0,-559.2), vec3(549.6,   0.0,   0.0), vec3(549.6, 548.8,   0.0), vec3(549.6, 548.8,-559.2), z, vec3(0.05, 0.05, 0.7 ), DIFF);// Right Wall Blue
	quads[3] = Quad( vec3( 0.0,-1.0, 0.0), vec3(  0.0, 548.8,-559.2), vec3(549.6, 548.8,-559.2), vec3(549.6, 548.8,   0.0), vec3(  0.0, 548.8,   0.0), z, vec3( 1.0,  1.0,  1.0), DIFF);// Ceiling
	quads[4] = Quad( vec3( 0.0, 1.0, 0.0), vec3(  0.0,   0.0,   0.0), vec3(549.6,   0.0,   0.0), vec3(549.6,   0.0,-559.2), vec3(  0.0,   0.0,-559.2), z, vec3( 1.0,  1.0,  1.0), DIFF);// Floor

	quads[5] = Quad( vec3( 0.0,-1.0, 0.0), vec3(213.0, 548.0,-332.0), vec3(343.0, 548.0,-332.0), vec3(343.0, 548.0,-227.0), vec3(213.0, 548.0,-227.0), L1, z, LIGHT);// Area Light Rectangle in ceiling
}


#include <pathtracing_main>
