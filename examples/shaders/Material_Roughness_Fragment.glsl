precision highp float;
precision highp int;
precision highp sampler2D;

#include <pathtracing_uniforms_and_defines>
uniform int uMaterialType;
uniform vec3 uMaterialColor;

#define N_LIGHTS 3.0
#define N_SPHERES 15

//-----------------------------------------------------------------------

vec3 rayOrigin, rayDirection;
// recorded intersection data:
vec3 hitNormal, hitEmission, hitColor;
vec2 hitUV;
float hitRoughness;
float hitObjectID;
int hitType;


struct Sphere { float radius; vec3 position; vec3 emission; vec3 color; float roughness; int type; };

Sphere spheres[N_SPHERES];


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_sample_sphere_light>


//---------------------------------------------------------------------------------------
float SceneIntersect( )
//---------------------------------------------------------------------------------------
{
	float d;
	float t = INFINITY;
	vec3 n;
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
                        hitRoughness = spheres[i].roughness;
			hitType = spheres[i].type;
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
	Sphere lightChoice;

	vec3 accumCol = vec3(0);
        vec3 mask = vec3(1);
	vec3 checkCol0 = vec3(1);
	vec3 checkCol1 = vec3(0.5);
	vec3 dirToLight;
	vec3 tdir;
	vec3 x, n, nl, normal;
        
	float t;
	float nc, nt, ratioIoR, Re, Tr;
	float P, RP, TP;
	float weight;
	float thickness = 0.05;
	float previousIntersectionRoughness = 0.0;

	int diffuseCount = 0;

	bool coatTypeIntersected = false;
	bool bounceIsSpecular = true;
	bool sampleLight = false;

	lightChoice = spheres[int(rand() * N_LIGHTS)];

	
	for (int bounces = 0; bounces < 7; bounces++)
	{

		t = SceneIntersect();
		
		/*
		//not used in this scene because we are inside a huge sphere - no rays can escape
		if (t == INFINITY)
		{
                        break;
		}
		*/

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
		
		
		if (hitType == LIGHT)
		{	
			pixelSharpness = diffuseCount == 0 && previousIntersectionRoughness < 0.5 ? 1.01 : 0.0;

			if (bounceIsSpecular || sampleLight)
				accumCol = mask * hitEmission;
			// reached a light, so we can exit
			break;

		} // end if (hitType == LIGHT)


		if (sampleLight)// && hitType != REFR)
			break;


		    
                if (hitType == DIFF || hitType == CHECK) // Ideal DIFFUSE reflection
		{
			if( hitType == CHECK )
			{
				float q = clamp( mod( dot( floor(x.xz * 0.04), vec2(1.0) ), 2.0 ) , 0.0, 1.0 );
				hitColor = checkCol0 * q + checkCol1 * (1.0 - q);	
			}

			if (diffuseCount == 0 && !coatTypeIntersected && previousIntersectionRoughness < 0.4)	
				objectColor = hitColor;

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

			dirToLight = sampleSphereLight(x, nl, lightChoice, weight);
			mask *= weight * N_LIGHTS;

			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;

			sampleLight = true;
			continue;
                        
		} // end if (hitType == DIFF)
		
		if (hitType == SPEC)  // Ideal SPECULAR reflection
		{
			previousIntersectionRoughness = hitRoughness;

			mask *= hitColor;
			rayDirection = reflect(rayDirection, nl);
			rayDirection = randomDirectionInSpecularLobe(rayDirection, hitRoughness);
			rayOrigin = x + nl * uEPS_intersect;

			// if (diffuseCount == 1)
			// 	bounceIsSpecular = true; // turn on mirror caustics
			continue;
		}
		
		if (hitType == REFR)  // Ideal dielectric REFRACTION
		{
			if (diffuseCount == 0 && hitRoughness < 0.5 && !uCameraIsMoving )
				pixelSharpness = 1.01;
			else if (diffuseCount > 0)
				pixelSharpness = 0.0;
			else
				pixelSharpness = -1.0;

			previousIntersectionRoughness = hitRoughness;

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
				rayDirection = randomDirectionInSpecularLobe(rayDirection, hitRoughness);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			// transmit ray through surface
			// is ray leaving a solid object from the inside? 
			// If so, attenuate ray color with object color by how far ray has travelled through the medium
			if (distance(n, nl) > 0.1)
			{
				mask *= exp(log(hitColor) * thickness * t);
			}

			mask *= TP;
			
			tdir = refract(rayDirection, nl, ratioIoR);
			rayDirection = tdir;
			rayDirection = randomDirectionInSpecularLobe(rayDirection, hitRoughness * hitRoughness);
			rayOrigin = x - nl * uEPS_intersect;

			if (diffuseCount == 1)
				bounceIsSpecular = true; // turn on refracting caustics

			continue;
			
		} // end if (hitType == REFR)
		
		if (hitType == COAT)  // Diffuse object underneath with ClearCoat on top
		{
			pixelSharpness = 0.0;

			previousIntersectionRoughness = hitRoughness;
			coatTypeIntersected = true;

			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of Clear Coat
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);
			
			if (rand() < P)
			{
				if (diffuseCount == 0)
					pixelSharpness = -1.0;

				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayDirection = randomDirectionInSpecularLobe(rayDirection, hitRoughness);
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
			
			dirToLight = sampleSphereLight(x, nl, lightChoice, weight);
			mask *= weight * N_LIGHTS;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;

			sampleLight = true;
			continue;
                        
		} //end if (hitType == COAT)

		if (hitType == METALCOAT)  // Metal object underneath with ClearCoat on top
		{
			previousIntersectionRoughness = hitRoughness;

			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of Clear Coat
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
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

			mask *= TP;
			mask *= hitColor;
                        
			rayDirection = reflect(rayDirection, nl);
			rayDirection = randomDirectionInSpecularLobe(rayDirection, hitRoughness);
			rayOrigin = x + nl * uEPS_intersect;

			continue;
                        
		} //end if (hitType == METALCOAT)

		
	} // end for (int bounces = 0; bounces < 7; bounces++)
	
	
	return max(vec3(0), accumCol);

} // end vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )


//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);          
	vec3 L1 = vec3(1.0, 1.0, 1.0) * 13.0;// White light
	vec3 L2 = vec3(1.0, 0.8, 0.2) * 10.0;// Yellow light
	vec3 L3 = vec3(0.1, 0.7, 1.0) * 5.0; // Blue light
	
	vec3 color = uMaterialColor;
	int typeID = uMaterialType;
	
        spheres[0]  = Sphere(150.0, vec3(-400, 900, 200), L1, z, 0.0, LIGHT);//spherical white Light1 
	spheres[1]  = Sphere(100.0, vec3( 300, 400,-300), L2, z, 0.0, LIGHT);//spherical yellow Light2
	spheres[2]  = Sphere( 50.0, vec3( 500, 250,-100), L3, z, 0.0, LIGHT);//spherical blue Light3
	
	spheres[3]  = Sphere(1000.0, vec3(  0.0, 1000.0,  0.0), z, vec3(1.0, 1.0, 1.0), 0.0, CHECK);//Checkered Floor

        spheres[4]  = Sphere(  14.0, vec3(-150, 30, 0), z, color, 0.0, typeID);
        spheres[5]  = Sphere(  14.0, vec3(-120, 30, 0), z, color, 0.1, typeID);
        spheres[6]  = Sphere(  14.0, vec3( -90, 30, 0), z, color, 0.2, typeID);
        spheres[7]  = Sphere(  14.0, vec3( -60, 30, 0), z, color, 0.3, typeID);
        spheres[8]  = Sphere(  14.0, vec3( -30, 30, 0), z, color, 0.4, typeID);
        spheres[9]  = Sphere(  14.0, vec3(   0, 30, 0), z, color, 0.5, typeID);
        spheres[10] = Sphere(  14.0, vec3(  30, 30, 0), z, color, 0.6, typeID);
        spheres[11] = Sphere(  14.0, vec3(  60, 30, 0), z, color, 0.7, typeID);
        spheres[12] = Sphere(  14.0, vec3(  90, 30, 0), z, color, 0.8, typeID);
        spheres[13] = Sphere(  14.0, vec3( 120, 30, 0), z, color, 0.9, typeID);
        spheres[14] = Sphere(  14.0, vec3( 150, 30, 0), z, color, 1.0, typeID);
}


#include <pathtracing_main>
