# SVPB Tools

## Second Generation Vision

### Context - First Generation

The key problem being solved by the music tools is: every member of the Silicon Valley
Pipe Band needs to have access to up-to-date sheet music for the tunes the band plays.
While everyone in the band has access to a computer and to the Internet, the operating systems
and user skills are very different from person to person. For a while, one particular person
kept the scores on their personal computer using CelticPipes, and printed out sheet music
and distributed copies at practice. This put the burden of maintaining the music, including
updating scores with changes decided upon during practices, on a single person. When that
person was unavailable or had lots of other issues to deal with, music distribution was
delayed. Similarly, with only a single person being responsible for printing out scores,
they were bearing the technical, logistical, and economic burdens of music distribution.

The first generation music tools represents a distinct improvement over this manual,
centralized process. Details of this can be found in the [svpb-music] repository.

#### What Gen.1 Gets Right

The workflow from push to GitHub to fresh music appearing in the Box music folder is largely
automated. The only time manual intervention is required is when we switch from one year to the
next. It's very easy for multiple musicians to update scores and distribute them to the entire
band.

#### Opportunities for Improvement

Because there are a lot of distinct tools in the pipeline and because each tool carries its
own overhead of keeping up with security patches and updating configuration and sources, it
is not a system that is easy for anyone to maintain. The person doing the maintenance needs
to understand how to be an administrator of a Linux system, an Apache webserver, certbot, make,
GhostScript, Perl, and git. That's a lot to ask of someone who just likes to play music.

### Imagine G2

#### Simplification

What if all the conversion tools - `abcm2ps`, `gs`, `make`, and Perl were all bundled together
into a Docker image? That's actually been done, in the [zuleika] image. So then, the build server
would have to have some kind of web server that would respond to the GitHub webhook by:

  - pulling the source files from GitHub into a working directory
  - invoking the container (requires the server have docker installed) in the local directory
  - pushing the PDF artifacts out to the Box drive
  - notifying Slack

#### Make Your Own

What if you could make your own binder? Imagine that in a given year, the pipe major constructs a "binder" out of a list of tunes. For printing, the full binder would look like all of the tunes in the order that the pipe major specifies, including all of the harmonies.

But being able to personalize your binder would look like selecting individual tunes. So that, "Oh, I am supposed to play harmonies on tune number three, therefore I only care about showing the harmonies, part three of tune number three." And I don't care about the melody or harmonies one, two, and four. Print that out, generate the series of PDFs out of the ABC files, and at the footer of each page, include the page number within the specific binder that I've assembled.

Therefore, in the full binder, Harmony three might be page number, I don't know, twenty-seven. But because in the personalized binder I'm only including the tunes that I have to memorize, Harmony 3 might actually only be like the, I don't know, fifth page. The footer of that page would reflect the page number within the binder that is being printed. 


[svpb-music]: https://github.com/SVPB/svpb-music
[zuleika]: https://hub.docker.com/repository/docker/pirateguillermo/zuleika/general
